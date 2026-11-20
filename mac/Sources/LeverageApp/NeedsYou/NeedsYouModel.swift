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
    private(set) var busy: Set<UUID> = []
    private(set) var failures: [UUID: String] = [:]

    @ObservationIgnored private let api: any OwnerAPI
    @ObservationIgnored private let noteRead: @MainActor (Int) -> Void
    @ObservationIgnored private let openTask: @MainActor (UUID) -> Void
    @ObservationIgnored private let timing: FollowTiming
    /// The key of each command sent, kept until the server has answered it.
    @ObservationIgnored private var keys: [String: IdempotencyKey] = [:]
    @ObservationIgnored private var names = NeedsYouNames()
    @ObservationIgnored private var subscription: EventFeed.Subscription?
    @ObservationIgnored private var generation = 0

    init(
        api: any OwnerAPI, noteRead: @escaping @MainActor (Int) -> Void,
        openTask: @escaping @MainActor (UUID) -> Void, timing: FollowTiming = .normal
    ) {
        self.api = api
        self.noteRead = noteRead
        self.openTask = openTask
        self.timing = timing
    }

    func isWaitingForSignIn(_ id: UUID) -> Bool { waitingForSignIn.contains(id) }
    func signInWaitingLine(_ id: UUID) -> String? { waitingForSignIn.contains(id) ? NeedsYouCopy.signInWaiting.text : nil }
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
            guard mine == generation else { return }
            rows = page.items.filter { $0.state == .open }.sorted { $0.openedSeq < $1.openedSeq }
                .map { row(for: $0) }
            let live = Set(rows.map(\.id))
            failures = failures.filter { live.contains($0.key) }
            if let confirming = confirmingCancel, !live.contains(confirming) { confirmingCancel = nil }
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

    private func row(for item: InboxItem) -> NeedsYouRow {
        NeedsYouRow(
            id: item.id, kind: item.kind, taskID: NeedsYouWords.taskID(of: item),
            credentialID: NeedsYouWords.credentialID(of: item),
            heading: NeedsYouWords.heading(for: item, names: names),
            body: NeedsYouWords.body(for: item, names: names), buttons: NeedsYouWords.buttons(for: item))
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
            defer { self.waitingForSignIn.remove(row.id) }
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
