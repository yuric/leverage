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

/// One task's page (L799, MA-9, MA-29): the contract, the criteria with their
/// evidence, where the work is, the log, and what the owner can do: Send to
/// agents for a task left in Backlog (MA-16), Allow one more try and Cancel task
/// for a task paused at the limit, and Cancel task for any task not finished.
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

    @ObservationIgnored private let clock: ResetClock

    init(taskID: UUID, api: any OwnerAPI, noteRead: @escaping @MainActor (Int) -> Void, clock: ResetClock = .system) {
        self.taskID = taskID
        self.api = api
        self.noteRead = noteRead
        self.clock = clock
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

    private var openHolds: [Hold] { page?.holds.filter { $0.closedAt == nil } ?? [] }

    /// The card's words for this task, from the read.
    var status: CardContent? {
        guard let page else { return nil }
        let holds = openHolds
        let waiting = holds.first { $0.credentialID != nil }
        let card = BoardTask(
            task: page.task, blocked: !holds.isEmpty, holdReasons: holds.map(\.reason),
            waitingForCredentialID: waiting?.credentialID)
        return CardWording.content(for: card, seatNames: seatNames, reviewerSeatExists: page.reviewerSeatExists)
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
        return TaskLog.entries(events: page.events, names: page.names, criteria: page.criteria)
    }

    // MARK: what the owner can do

    /// A task left in Backlog shows its form, filled in (MA-16).
    var showsContractForm: Bool { page?.task.state == .backlog }

    var canSend: Bool { showsContractForm && !isBusy && !draft.trimmedTitle.isEmpty }

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

    var canMoveToBacklog: Bool { false }
    var canPause: Bool { false }
    var canContinue: Bool { false }
    var canChangeTask: Bool { false }
    private(set) var editor: EditContractModel?

    func moveToBacklog() async {}
    func pauseTask() async {}
    func continueTask() async {}
    func beginEditing() {}
    func endEditing() {}

    // MARK: reading

    func load() async {
        generation += 1
        let mine = generation
        do {
            let read = try await api.task(id: taskID)
            guard mine == generation else { return }
            page = read
            prefillIfUntouched(from: read)
            state = .loaded
            noteRead(read.asOfSeq)
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
            _ = try await self.api.completeContract(taskID: self.taskID, request, key: key).completedResult()
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
        defer { isBusy = false }
        do {
            try await command()
            return true
        } catch {
            actionFailure = ShellCopy.sentence(for: error)
            return false
        }
    }
}
