import Foundation
import LeverageKit
import Observation

/// The contract editor of a task that already has a contract: the same form as
/// Add task, filled in with the task's own words (HM-49, HE-25).
///
/// Save sends Edit contract. Save and send to agents sends it and then Complete
/// contract, as the form does for a new task. Criteria the owner leaves as they
/// were are sent with their text untouched, so the server keeps them with what
/// has passed (HE-25); the independent review keeps the words it has.
///
/// A key is kept while its command has not been answered, so pressing the button
/// again sends the same command; it is dropped when the form changes, because the
/// server refuses one key with two bodies. If the edit worked and Complete
/// contract did not, the next press sends only Complete contract.
@MainActor
@Observable
final class EditContractModel {
    enum State: Equatable, Sendable {
        case editing
        case saving
        case saved
        case failed(ShellCopy)
    }

    private(set) var state: State = .editing

    var draft: ContractDraft {
        didSet {
            guard draft != oldValue else { return }
            editKey = nil
            completeKey = nil
            edited = false
        }
    }

    let taskID: UUID
    /// What Save does, said first from a state where an agent may be at work (HM-49).
    let warning: AddTaskCopy?

    @ObservationIgnored private let api: any OwnerAPI
    @ObservationIgnored private let onSaved: @MainActor () -> Void
    @ObservationIgnored private var editKey: IdempotencyKey?
    @ObservationIgnored private var completeKey: IdempotencyKey?
    /// The edit worked for this form; only Complete contract is left to send.
    @ObservationIgnored private var edited = false

    init(page: TaskPage, api: any OwnerAPI, onSaved: @escaping @MainActor () -> Void) {
        taskID = page.task.id
        self.api = api
        self.onSaved = onSaved
        // An agent stops only where one holds the task: a builder in Working,
        // a reviewer on an In review task's open review. Ready has no holder.
        let reviewerHolds = page.reviews.contains { $0.reviewerSeatID != nil && $0.verdict == nil }
        switch page.task.state {
        case .working: warning = .editWarning
        case .inReview: warning = reviewerHolds ? .editWarning : .editWarningNoAgent
        case .ready: warning = .editWarningNoAgent
        default: warning = nil
        }

        var filled = ContractDraft()
        filled.title = page.task.title
        filled.goal = page.task.goal
        filled.details = page.task.details ?? ""
        filled.workReference = page.task.workReference ?? ""
        filled.priority = page.task.priority
        let ordered = page.criteria.sorted { $0.position < $1.position }
        filled.criteriaText = ordered.filter { $0.kind == .build }.map(\.text).joined(separator: "\n")
        if let review = ordered.first(where: { $0.kind == .review }) { filled.reviewCriterionText = review.text }
        draft = filled
    }

    var isBusy: Bool { state == .saving }

    /// Whether the buttons are on: there is a title and nothing is being sent.
    var canSave: Bool { !isBusy && state != .saved && !draft.trimmedTitle.isEmpty }

    /// The failure line, if the last try did not work.
    var failure: ShellCopy? {
        if case .failed(let copy) = state { copy } else { nil }
    }

    /// The edit was saved but the task was not sent to agents.
    var savedWithoutSending: Bool {
        if case .failed = state { edited } else { false }
    }

    /// Save: Edit contract alone.
    func save() async { await send(thenComplete: false) }

    /// Save and send to agents: Edit contract, then Complete contract.
    func saveAndSend() async { await send(thenComplete: true) }

    private func send(thenComplete: Bool) async {
        guard canSave else { return }
        state = .saving
        let request = draft.completeRequest()
        do {
            if !edited {
                let key = editKey ?? IdempotencyKey()
                editKey = key
                _ = try await api.editContract(taskID: taskID, request, key: key).completedResult()
                edited = true
            }
            if thenComplete {
                let key = completeKey ?? IdempotencyKey()
                completeKey = key
                try await api.completeContract(taskID: taskID, request, key: key).acceptedWhilePending()
            }
            state = .saved
            onSaved()
        } catch {
            state = .failed(ShellCopy.sentence(for: error))
        }
    }
}
