import Foundation
import LeverageKit
import Observation

/// A piece of evidence on a criterion: a link or a note, shown as plain text
/// and never opened (L533).
struct EvidenceRow: Identifiable, Equatable, Sendable {
    let id: UUID
    let kindText: String
    let value: String
}

/// One criterion of the task with where it stands and its evidence.
struct CriterionRow: Identifiable, Equatable, Sendable {
    let id: UUID
    let text: String
    let stateText: String
    let isDone: Bool
    let evidence: [EvidenceRow]
}

/// One task's page (L799, MA-9, MA-29, HM-43 to HM-49): the contract, the
/// criteria with their evidence, where the work is, the log, and what the owner
/// can do: Send to agents for a task left in Backlog (MA-16), Move to Backlog
/// for an idea, Change the task, Pause this task and Continue this task, Allow
/// one more try and Cancel task for a task paused at the limit, and Cancel task
/// for any task not finished.
///
/// A command's key is kept until it works, so Retry sends the same command and
/// a repeat writes nothing twice (IN-9). The form of a Backlog task is not
/// overwritten by a later read while the owner has typed into it.
@MainActor
@Observable
final class TaskPageModel {
    enum State: Equatable, Sendable {
        case loading
        case loaded
        case notFound
        case failed(ShellCopy)
        /// The sign-in ended. The shell returns the app to Sign in.
        case signedOut
    }

    let taskID: UUID
    private(set) var state: State = .loading
    private(set) var page: TaskPage?
    /// The form of a Backlog task.
    var draft = ContractDraft() {
        didSet {
            guard !prefilling, draft != oldValue else { return }
            draftTouched = true
            sendKey = nil
        }
    }
    private(set) var isBusy = false
    /// Why the last button did not work.
    private(set) var actionFailure: ShellCopy?
    /// The error of the last command that failed, which says whether its key is kept.
    @ObservationIgnored private var lastError: (any Error)?
    private(set) var isConfirmingCancel = false

    @ObservationIgnored private let api: any OwnerAPI
    @ObservationIgnored private let noteRead: @MainActor (Int) -> Void
    @ObservationIgnored private var subscription: EventFeed.Subscription?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var prefilling = false
    @ObservationIgnored private var draftTouched = false
    @ObservationIgnored private var sendKey: IdempotencyKey?
    @ObservationIgnored private var allowKey: IdempotencyKey?
    @ObservationIgnored private var cancelKey: IdempotencyKey?
    @ObservationIgnored private var promoteKey: IdempotencyKey?
    @ObservationIgnored private var holdKey: IdempotencyKey?
    @ObservationIgnored private var resumeKey: IdempotencyKey?
    @ObservationIgnored private var rerunKeys: [UUID: IdempotencyKey] = [:]
    @ObservationIgnored private var draftKey: IdempotencyKey?
    @ObservationIgnored private var accounts: [UUID: CardAccount] = [:]
    @ObservationIgnored private var accountNames: [UUID: String] = [:]

    @ObservationIgnored let clock: ResetClock
    /// Opened from Needs you's Change the task: the first read opens the
    /// editor (HM-24, HM-49).
    @ObservationIgnored private var editOnOpen: Bool

    init(
        taskID: UUID, api: any OwnerAPI, noteRead: @escaping @MainActor (Int) -> Void, clock: ResetClock = .system,
        editOnOpen: Bool = false
    ) {
        self.taskID = taskID
        self.api = api
        self.noteRead = noteRead
        self.clock = clock
        self.editOnOpen = editOnOpen
    }

    // MARK: what the page shows

    var title: String { page?.task.title ?? "" }
    var goal: String { page?.task.goal ?? "" }
    var details: String? { nonEmpty(page?.task.details) }
    var workReference: String? { nonEmpty(page?.task.workReference) }

    var priorityText: String {
        switch page?.task.priority ?? .normal {
        case .low: AddTaskCopy.priorityLow.text
        case .normal: AddTaskCopy.priorityNormal.text
        case .high: AddTaskCopy.priorityHigh.text
        }
    }

    private func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    private var seatNames: [UUID: String] {
        guard let page else { return [:] }
        return Dictionary(
            page.names.filter { $0.kind == .seat }.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    }

    var openHolds: [Hold] { page?.holds.filter { $0.closedAt == nil } ?? [] }

    /// The names of the accounts the page can say: the read's own names, and
    /// where the accounts could be read, the provider and name as the owner knows them.
    private var cardAccounts: [UUID: CardAccount] {
        guard let page else { return [:] }
        var known = Dictionary(
            page.names.filter { $0.kind == .credential }.map { ($0.id, CardAccount(name: $0.name)) },
            uniquingKeysWith: { first, _ in first })
        known.merge(accounts) { _, read in read }
        return known
    }

    /// The card's words for this task, from the read: the account it waits
    /// for and when it resets are the card's own fields (HE-15, HE-16).
    var status: CardContent? {
        guard let page else { return nil }
        let holds = openHolds
        let card = BoardTask(
            task: page.task, blocked: !holds.isEmpty, holdReasons: holds.map(\.reason),
            waitingForCredentialID: page.waitingForCredentialID, waitingUntil: page.waitingUntil,
            checking: page.pending != nil && holds.isEmpty, checkReason: contractCheckReason)
        return CardWording.content(
            for: card, seatNames: seatNames, reviewerSeatExists: page.reviewerSeatExists, accounts: cardAccounts,
            clock: clock)
    }

    var criteria: [CriterionRow] {
        (page?.criteria ?? []).sorted { $0.position < $1.position }.map { criterion in
            let stateText: String
            switch criterion.state {
            case .open: stateText = TaskPageCopy.criterionOpen.text
            case .started: stateText = TaskPageCopy.criterionStarted.text
            case .passed: stateText = TaskPageCopy.criterionPassed.text
            }
            let evidence = criterion.evidence.map {
                EvidenceRow(
                    id: $0.id,
                    kindText: $0.kind == .link ? TaskPageCopy.evidenceLink.text : TaskPageCopy.evidenceNote.text,
                    value: $0.value)
            }
            return CriterionRow(
                id: criterion.id, text: criterion.text, stateText: stateText, isDone: criterion.state == .passed,
                evidence: evidence)
        }
    }

    var log: [LogEntry] {
        guard let page else { return [] }
        return TaskLog.entries(
            events: page.events, names: page.names, criteria: page.criteria, recoveryTimes: page.recoveryTimes,
            accounts: accountNames, ruleChecks: page.ruleChecks, clock: clock)
    }

    // MARK: what the owner can do

    /// A task left in Backlog shows its form, filled in (MA-16).
    var showsContractForm: Bool { page?.task.state == .backlog }

    /// A task whose command waits for its checks is not sent again (RD-27).
    var canSend: Bool { showsContractForm && !isBusy && page?.pending == nil && !draft.trimmedTitle.isEmpty }

    /// A task paused at the round limit offers two choices (MA-29).
    var needsRoundDecision: Bool {
        guard let state = page?.task.state, state != .done, state != .cancelled else { return false }
        return openHolds.contains { $0.reason == .roundsExceeded }
    }

    /// Every task that is not Done or Cancelled can be cancelled (MA-29).
    var canCancel: Bool {
        guard let state = page?.task.state else { return false }
        return state != .done && state != .cancelled && !isBusy
    }

    /// An idea moves to Backlog (HM-45).
    var canMoveToBacklog: Bool { page?.task.state == .imaginarium && !isBusy }

    /// Pause this task: every state it can be paused from, while it is not already
    /// paused by the owner (HE-24). Finishing is left out: no task is in it yet (HS-3).
    var canPause: Bool {
        guard let state = page?.task.state, !isBusy else { return false }
        return [.backlog, .ready, .working, .inReview].contains(state) && !hasOwnerPause
    }

    /// Continue this task: only while the owner's own pause is open.
    var canContinue: Bool {
        guard let state = page?.task.state, state != .done, state != .cancelled, !isBusy else { return false }
        return hasOwnerPause
    }

    private var hasOwnerPause: Bool { openHolds.contains { $0.reason == .ownerHold } }

    /// Change the task: the contract editor, for a task an agent may be working on.
    /// A Backlog task shows its form instead (MA-16), and an idea moves first.
    var canChangeTask: Bool {
        guard let state = page?.task.state else { return false }
        return [.ready, .working, .inReview].contains(state)
    }

    private(set) var editor: EditContractModel?
    /// The sheet that asks why a check is let through, while it is open.
    private(set) var letThrough: LetThroughModel?

    /// Let it through once: opens the sheet that asks why, for a check the page says can be let through.
    func askToLetThrough(_ checkID: UUID) {
        guard let page, let check = page.ruleChecks.first(where: { $0.id == checkID }),
            check.canOverride, check.overriddenAt == nil
        else { return }
        letThrough = LetThroughModel(
            check: check, page: page, api: api,
            onDone: { [weak self] in
                self?.letThrough = nil
                Task { await self?.load() }
            })
    }

    func dismissLetThrough() { letThrough = nil }

    /// Run it again, for an errored check: the same command is sent again until it works.
    func runAgain(_ checkID: UUID) async {
        guard checks.first(where: { $0.id == checkID })?.canRunAgain == true else { return }
        let key = rerunKeys[checkID] ?? IdempotencyKey()
        rerunKeys[checkID] = key
        let sent = await run { try await self.api.rerunCheck(checkID: checkID, key: key).acceptedWhilePending() }
        if sent {
            rerunKeys[checkID] = nil
            await load()
        } else if !keyIsKept {
            rerunKeys[checkID] = nil
        }
    }

    /// Draft the details: a planner writes the contract of a Backlog task.
    func draftDetails() async {
        guard canDraftDetails else { return }
        let key = draftKey ?? IdempotencyKey()
        draftKey = key
        let sent = await run { try await self.api.draftContract(taskID: self.taskID, key: key).acceptedWhilePending() }
        if sent {
            draftKey = nil
            await load()
        } else if !keyIsKept {
            draftKey = nil
        }
    }

    func moveToBacklog() async {
        guard canMoveToBacklog else { return }
        let key = promoteKey ?? IdempotencyKey()
        promoteKey = key
        let moved = await run { _ = try await self.api.promoteTask(taskID: self.taskID, key: key).completedResult() }
        if moved {
            promoteKey = nil
            await load()
        } else if !keyIsKept {
            promoteKey = nil
        }
    }

    func pauseTask() async {
        guard canPause else { return }
        let key = holdKey ?? IdempotencyKey()
        holdKey = key
        let paused = await run { _ = try await self.api.holdTask(taskID: self.taskID, key: key).completedResult() }
        if paused {
            holdKey = nil
            await load()
        } else if !keyIsKept {
            holdKey = nil
        }
    }

    func continueTask() async {
        guard canContinue else { return }
        let key = resumeKey ?? IdempotencyKey()
        resumeKey = key
        let resumed = await run { _ = try await self.api.resumeTask(taskID: self.taskID, key: key).completedResult() }
        if resumed {
            resumeKey = nil
            await load()
        } else if !keyIsKept {
            resumeKey = nil
        }
    }

    /// Opens the editor, filled in with the task's contract (HM-49).
    func beginEditing() {
        guard canChangeTask, let page else { return }
        editor = EditContractModel(
            page: page, api: api,
            onSaved: { [weak self] in
                self?.editor = nil
                Task { await self?.load() }
            })
    }

    func endEditing() { editor = nil }

    // MARK: reading

    func load() async {
        generation += 1
        let mine = generation
        do {
            let read = try await api.task(id: taskID)
            var position = read.asOfSeq
            var readAccounts = accounts
            if read.waitingForCredentialID != nil || read.names.contains(where: { $0.kind == .credential })
                || read.holds.contains(where: { $0.credentialID != nil }) {
                // The provider and the reset time are a nicety: the page still names the account without them.
                do {
                    let list = try await api.credentials()
                    readAccounts = Dictionary(
                        list.credentials.map { ($0.credential.id, CardAccount(of: $0.credential)) },
                        uniquingKeysWith: { first, _ in first })
                    position = min(position, list.asOfSeq)
                } catch let error as TransportError where error.code == .unauthenticated {
                    throw error
                } catch is CancellationError {
                    throw CancellationError()
                } catch {}
            }
            guard mine == generation else { return }
            accounts = readAccounts
            accountNames = readAccounts.mapValues(\.name)
            page = read
            prefillIfUntouched(from: read)
            state = .loaded
            noteRead(position)
            if editOnOpen {
                editOnOpen = false
                beginEditing()
            }
        } catch is CancellationError {
            return
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch let error as TransportError where error.code == .unauthenticated {
            if mine == generation { state = .signedOut }
        } catch let error as TransportError where error.code == .notFound {
            if mine == generation { state = .notFound }
        } catch {
            if mine == generation { state = .failed(ShellCopy.sentence(for: error)) }
        }
    }

    private func prefillIfUntouched(from page: TaskPage) {
        guard page.task.state == .backlog, !draftTouched else { return }
        var filled = ContractDraft()
        filled.title = page.task.title
        filled.goal = page.task.goal
        filled.details = page.task.details ?? ""
        filled.workReference = page.task.workReference ?? ""
        filled.priority = page.task.priority
        filled.criteriaText = page.criteria.filter { $0.kind == .build }
            .sorted { $0.position < $1.position }.map(\.text).joined(separator: "\n")
        prefilling = true
        draft = filled
        prefilling = false
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

    // MARK: commands

    /// Send to agents: Complete contract with the form's values (MA-16).
    func sendToAgents() async {
        guard canSend else { return }
        let key = sendKey ?? IdempotencyKey()
        sendKey = key
        let request = draft.completeRequest()
        let sent = await run {
            try await self.api.completeContract(taskID: self.taskID, request, key: key).acceptedWhilePending()
        }
        if sent {
            sendKey = nil
            draftTouched = false
            await load()
        }
    }

    /// Allow one more try for a task paused at the round limit.
    func allowAnotherRound() async {
        let key = allowKey ?? IdempotencyKey()
        allowKey = key
        let allowed = await run { _ = try await self.api.allowAnotherRound(taskID: self.taskID, key: key).completedResult() }
        if allowed {
            allowKey = nil
            await load()
        }
    }

    func askToCancel() {
        guard canCancel else { return }
        isConfirmingCancel = true
    }

    func dismissCancel() { isConfirmingCancel = false }

    /// Cancel task, after the owner confirmed.
    func confirmCancel() async {
        isConfirmingCancel = false
        let key = cancelKey ?? IdempotencyKey()
        cancelKey = key
        let cancelled = await run { _ = try await self.api.cancelTask(taskID: self.taskID, key: key).completedResult() }
        if cancelled {
            cancelKey = nil
            await load()
        }
    }

    /// Runs one command: busy while it is out, its failure kept as a plain line.
    private func run(_ command: () async throws -> Void) async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        actionFailure = nil
        lastError = nil
        defer { isBusy = false }
        do {
            try await command()
            return true
        } catch {
            lastError = error
            actionFailure = ShellCopy.sentence(for: error)
            return false
        }
    }

    /// Whether the last command that failed keeps its key for the next press
    /// (`IdempotencyKey.isKept(after:)`): not after a refusal.
    private var keyIsKept: Bool { lastError.map(IdempotencyKey.isKept(after:)) ?? true }
}
