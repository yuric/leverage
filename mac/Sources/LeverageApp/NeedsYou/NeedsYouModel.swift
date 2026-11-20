import Foundation
import LeverageKit
import Observation

/// One Needs you item as a row of the screen.
struct NeedsYouRow: Identifiable, Equatable, Sendable {
    let id: UUID
    let kind: NeedsYouItem
    let taskID: UUID?
    let credentialID: UUID?
    let heading: String
    let body: String
    let buttons: [NeedsYouButton]
    /// The rule the item is about, by its name; nil when it names none or the read could not say.
    var ruleName: String?
    /// What the check said, as the checker wrote it: data, never an instruction.
    var reason: String?
    /// The rule and the rule check the item names, for its buttons.
    var ruleID: UUID?
    var checkID: UUID?
}

/// The Needs you screen (HM-21, HM-24): the open items from `list_inbox`, a
/// row for each, and the commands of its buttons. An item of a kind the app
/// cannot open yet is one plain line with no button.
@MainActor
@Observable
final class NeedsYouModel {
    enum State: Equatable, Sendable {
        case loading
        case loaded
        case failed(ShellCopy)
        /// The sign-in ended. The shell returns the app to Sign in.
        case signedOut
    }

    private(set) var state: State = .loading
    private(set) var rows: [NeedsYouRow] = []
    /// The row whose Cancel task is waiting for the owner's answer.
    private(set) var confirmingCancel: UUID?
    private(set) var waitingForSignIn: Set<UUID> = []
    /// The provider of the account each waiting row signs in to.
    private var waitingProviders: [UUID: Provider] = [:]
    private(set) var busy: Set<UUID> = []
    private(set) var failures: [UUID: String] = [:]

    @ObservationIgnored private let api: any OwnerAPI
    @ObservationIgnored private let noteRead: @MainActor (Int) -> Void
    @ObservationIgnored private let openTask: @MainActor (UUID) -> Void
    @ObservationIgnored private let timing: FollowTiming
    @ObservationIgnored private let openAgents: @MainActor () -> Void
    /// The key of each command sent, kept until the server has answered it.
    @ObservationIgnored private var keys: [String: IdempotencyKey] = [:]
    @ObservationIgnored private var names = NeedsYouNames()
    /// What the rule items name, read each time the screen reads (the rule of
    /// each check, by the check's id, and the name of each rule, by its id).
    @ObservationIgnored private var checkNotes: [UUID: CheckNote] = [:]
    @ObservationIgnored private var ruleNames: [UUID: String] = [:]
    @ObservationIgnored private var subscription: EventFeed.Subscription?
    @ObservationIgnored private var generation = 0

    init(
        api: any OwnerAPI, noteRead: @escaping @MainActor (Int) -> Void,
        openTask: @escaping @MainActor (UUID) -> Void, openAgents: @escaping @MainActor () -> Void = {},
        timing: FollowTiming = .normal
    ) {
        self.api = api
        self.noteRead = noteRead
        self.openTask = openTask
        self.openAgents = openAgents
        self.timing = timing
    }

    // MARK: Let it through once, and Turn the rule off

    /// The row whose "Let it through once" is waiting for the owner's reason.
    private(set) var letThroughRow: UUID?
    var letThroughReason = ""
    /// The row whose "Turn the rule off" is waiting for the owner's answer.
    private(set) var confirmingTurnOff: UUID?

    private var trimmedReason: String { letThroughReason.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Whether the reason is written and nothing else is out for the row.
    var canLetThrough: Bool {
        guard let id = letThroughRow else { return false }
        return !trimmedReason.isEmpty && !busy.contains(id)
    }

    func dismissLetThrough() {
        letThroughRow = nil
        letThroughReason = ""
    }

    /// Sends the owner's reason with the override of the check the item
    /// names. The reason is kept, with a plain line on the row, when the
    /// command did not work.
    func confirmLetThrough() async {
        guard canLetThrough, let id = letThroughRow, let check = rows.first(where: { $0.id == id })?.checkID else {
            return
        }
        let reason = trimmedReason
        await command(on: id, name: "let-through-\(reason)") { key in
            _ = try await self.api.overrideCheck(checkID: check, OverrideCheckRequest(reason: reason), key: key)
                .completedResult()
            self.dismissLetThrough()
        }
    }

    func dismissTurnOff() { confirmingTurnOff = nil }

    /// Turn the rule off, after the owner confirmed: it ends the rule's
    /// checks in flight and lets the work they held continue.
    func confirmTurnOff() async {
        guard let id = confirmingTurnOff, let rule = rows.first(where: { $0.id == id })?.ruleID else { return }
        confirmingTurnOff = nil
        await command(on: id, name: "turn-off") { key in
            _ = try await self.api.disableRule(ruleID: rule, key: key).completedResult()
        }
    }

    func isWaitingForSignIn(_ id: UUID) -> Bool { waitingForSignIn.contains(id) }
    /// The line a row shows while Sign in again waits for the owner, or nil:
    /// Antigravity has no sign-in command, so no window opens for Gemini.
    func signInWaitingLine(_ id: UUID) -> String? {
        guard waitingForSignIn.contains(id) else { return nil }
        return (waitingProviders[id] == .gemini ? NeedsYouCopy.signInWaitingGemini : .signInWaiting).text
    }
    func isBusy(_ id: UUID) -> Bool { busy.contains(id) }
    /// The line a command that did not work left on that row.
    func failure(for id: UUID) -> String? { failures[id] }

    // MARK: reading

    /// Reads the board and the credentials for their names, then the open
    /// items. A read that fails keeps the rows already shown.
    func load() async {
        generation += 1
        let mine = generation
        do {
            // The names first: their position is where the events tail starts,
            // so an event between the two reads is delivered again, not lost.
            var seq: Int?
            do {
                let read = try await NeedsYouNames.read(from: api)
                names = read.names
                seq = read.asOfSeq
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as TransportError where error.code == .unauthenticated {
                throw error
            } catch {
                // Without names the items still show, with plain stand-ins.
                names = NeedsYouNames()
            }
            let page = try await api.listInbox(afterSeq: nil, wait: nil)
            let open = page.items.filter { $0.state == .open }.sorted { $0.openedSeq < $1.openedSeq }
            names = await names.checkingOrchestrator(for: open, from: api)
            let notes = try await readRuleNotes(for: open)
            guard mine == generation else { return }
            (checkNotes, ruleNames) = notes
            rows = open.map { row(for: $0) }
            let live = Set(rows.map(\.id))
            failures = failures.filter { live.contains($0.key) }
            if let confirming = confirmingCancel, !live.contains(confirming) { confirmingCancel = nil }
            if let asking = letThroughRow, !live.contains(asking) { dismissLetThrough() }
            if let asking = confirmingTurnOff, !live.contains(asking) { confirmingTurnOff = nil }
            state = .loaded
            if let seq { noteRead(seq) }
        } catch is CancellationError {
            return
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch let error as TransportError where error.code == .unauthenticated {
            if mine == generation { state = .signedOut }
        } catch {
            if mine == generation { state = .failed(ShellCopy.sentence(for: error)) }
        }
    }

    /// A check as the task page reads it: the rule's name and what the check said.
    private struct CheckNote {
        let ruleName: String
        let reason: String?
    }

    /// Reads the rule's name and the reason for each item that names a rule.
    /// A task's page is read once however many of its checks are named, and
    /// the rules list only when a name is still missing. A read that fails
    /// leaves the row without them; a 401 or a cancel ends the load.
    private func readRuleNotes(for items: [InboxItem]) async throws -> ([UUID: CheckNote], [UUID: String]) {
        let ruleItems = items.filter { NeedsYouWords.namesARule($0.kind) }
        guard !ruleItems.isEmpty else { return ([:], [:]) }
        var notes: [UUID: CheckNote] = [:]
        var tasks: [UUID] = []
        for item in ruleItems where NeedsYouWords.checkID(of: item) != nil {
            if let task = NeedsYouWords.taskID(of: item), !tasks.contains(task) { tasks.append(task) }
        }
        for task in tasks {
            do {
                for check in try await api.task(id: task).ruleChecks {
                    let reason = check.reason?.trimmingCharacters(in: .whitespacesAndNewlines)
                    notes[check.id] = CheckNote(
                        ruleName: check.ruleName, reason: reason.flatMap { $0.isEmpty ? nil : $0 })
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as TransportError where error.code == .unauthenticated {
                throw error
            } catch {}
        }
        var rules: [UUID: String] = [:]
        let missing = ruleItems.contains { item in
            NeedsYouWords.checkID(of: item).flatMap { notes[$0] } == nil && NeedsYouWords.ruleID(of: item) != nil
        }
        if missing {
            do {
                for row in try await api.listRules().rules { rules[row.rule.id] = row.version.name }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as TransportError where error.code == .unauthenticated {
                throw error
            } catch {}
        }
        return (notes, rules)
    }

    private func row(for item: InboxItem) -> NeedsYouRow {
        let check = NeedsYouWords.checkID(of: item)
        let rule = NeedsYouWords.ruleID(of: item)
        let note = check.flatMap { checkNotes[$0] }
        var row = NeedsYouRow(
            id: item.id, kind: item.kind, taskID: NeedsYouWords.taskID(of: item),
            credentialID: NeedsYouWords.credentialID(of: item),
            heading: NeedsYouWords.heading(for: item, names: names),
            body: NeedsYouWords.body(for: item, names: names), buttons: NeedsYouWords.buttons(for: item))
        row.ruleName = note?.ruleName ?? rule.flatMap { ruleNames[$0] }
        row.reason = note?.reason
        row.ruleID = rule
        row.checkID = check
        return row
    }

    /// Reads again each time the events tail delivers a batch.
    func attach(to feed: EventFeed) {
        subscription?.cancel()
        subscription = feed.subscribe { [weak self] _ in
            Task { await self?.load() }
        }
    }

    func detach() {
        subscription?.cancel()
        subscription = nil
    }

    // MARK: the buttons

    /// Runs a button of a row. A button the row does not have sends nothing.
    func perform(_ action: NeedsYouButton.Action, on rowID: UUID) async {
        guard let row = rows.first(where: { $0.id == rowID }), row.buttons.contains(where: { $0.action == action }),
              !busy.contains(rowID)
        else { return }
        switch action {
        case .signInAgain: await signInAgain(row)
        case .allowAnotherTry: await allowAnotherTry(row)
        case .changeTask: if let task = row.taskID { openTask(task) }
        case .cancelTask: confirmingCancel = rowID
        case .letThroughOnce:
            guard row.checkID != nil else { return }
            letThroughRow = rowID
            letThroughReason = ""
        case .runAgain: await runAgain(row)
        case .turnRuleOff:
            guard row.ruleID != nil else { return }
            confirmingTurnOff = rowID
        case .connectAgent: openAgents()
        }
    }

    func dismissCancel() { confirmingCancel = nil }

    /// Cancel task, after the owner confirmed.
    func confirmCancel() async {
        guard let id = confirmingCancel, let task = rows.first(where: { $0.id == id })?.taskID else { return }
        confirmingCancel = nil
        await command(on: id, name: "cancel") { key in
            _ = try await self.api.cancelTask(taskID: task, key: key).completedResult()
        }
    }

    private func runAgain(_ row: NeedsYouRow) async {
        guard let check = row.checkID else { return }
        await command(on: row.id, name: "rerun") { key in
            _ = try await self.api.rerunCheck(checkID: check, key: key).completedResult()
        }
    }

    private func allowAnotherTry(_ row: NeedsYouRow) async {
        guard let task = row.taskID else { return }
        await command(on: row.id, name: "allow") { key in
            _ = try await self.api.allowAnotherRound(taskID: task, key: key).completedResult()
        }
    }

    /// Sign in again: asks the helper to open the provider's sign-in, shows
    /// that it is waiting for the owner, follows the request to its end, and
    /// reads again (MA-17).
    private func signInAgain(_ row: NeedsYouRow) async {
        guard let credential = row.credentialID else { return }
        let provider = names.provider(of: credential)
        await command(on: row.id, name: "signin", reads: false) { key in
            let outcome = try await self.api.signInAgain(credentialID: credential, key: key)
            _ = try outcome.completedResult()
            guard let requestID = outcome.helperRequestID else { return }
            self.keys["signin-\(row.id)"] = nil
            self.waitingForSignIn.insert(row.id)
            self.waitingProviders[row.id] = provider
            defer {
                self.waitingForSignIn.remove(row.id)
                self.waitingProviders[row.id] = nil
            }
            let follower = HelperRequestFollower(api: self.api, timing: self.timing)
            if let request = try await follower.follow(requestID, giveUpAfter: self.timing.giveUpAfter),
               !request.succeeded {
                self.failures[row.id] = CredentialsCopy.failureLine(for: request, provider: provider ?? .claude)
            }
        }
        await load()
    }

    /// Runs one command on a row: busy while it is out, its key kept until the
    /// server answered, and its failure kept as a plain line.
    private func command(
        on id: UUID, name: String, reads: Bool = true, _ send: (IdempotencyKey) async throws -> Void
    ) async {
        let slot = "\(name)-\(id)"
        let key = keys[slot] ?? IdempotencyKey()
        keys[slot] = key
        busy.insert(id)
        failures[id] = nil
        defer { busy.remove(id) }
        do {
            try await send(key)
            keys[slot] = nil
            if reads { await load() }
        } catch is CancellationError {
            return
        } catch {
            if CommandKey.wasAnswered(error) { keys[slot] = nil }
            failures[id] = ShellCopy.sentence(for: error).text
        }
    }
}
