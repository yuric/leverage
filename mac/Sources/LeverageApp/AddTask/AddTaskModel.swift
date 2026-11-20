import Foundation
import LeverageKit
import Observation

/// What the owner typed into the form: the values of Add task and of
/// Complete contract, which sends the same values again (IN-20). Shared by the
/// Add task sheet and by the form on a Backlog task's page (MA-16).
struct ContractDraft: Equatable, Sendable {
    var title = ""
    /// Empty means "use the title": the server requires a goal.
    var goal = ""
    var details = ""
    /// One criterion on each line.
    var criteriaText = ""
    var priority: Priority = .normal
    var workReference = ""
    /// The words of the independent review. A task that has one keeps its own
    /// words when the owner changes the task (HM-49).
    var reviewCriterionText = AddTaskCopy.reviewCriterion.text

    var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var effectiveGoal: String {
        let trimmed = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? trimmedTitle : trimmed
    }

    private static func nonEmpty(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The criteria the owner typed, then the independent review, which is
    /// always last (the server asks the client for it; trace 09).
    var criteria: [CriterionInput] {
        let typed = criteriaText.split(whereSeparator: \.isNewline)
            .compactMap { Self.nonEmpty(String($0)) }
            .map { CriterionInput(text: $0, kind: .build) }
        return typed + [CriterionInput(text: reviewCriterionText, kind: .review)]
    }

    /// Add task: into Backlog, with no criteria (they go with Complete contract).
    func addRequest() -> AddTaskRequest {
        AddTaskRequest(
            title: trimmedTitle, goal: effectiveGoal, priority: priority,
            workReference: Self.nonEmpty(workReference), state: .backlog)
    }

    /// Save as an idea: Add task alone, into the Imaginarium. It keeps the
    /// details too and leaves the criteria out, which are the contract's and
    /// go with Complete contract after Move to Backlog (HM-48).
    func ideaRequest() -> AddTaskRequest {
        AddTaskRequest(
            title: trimmedTitle, goal: effectiveGoal, details: Self.nonEmpty(details), priority: priority,
            workReference: Self.nonEmpty(workReference), state: .imaginarium)
    }

    /// Whether the owner typed criteria, which an idea does not keep.
    var hasTypedCriteria: Bool {
        criteriaText.split(whereSeparator: \.isNewline).contains { Self.nonEmpty(String($0)) != nil }
    }

    /// Complete contract: every field, the form's values sent again.
    func completeRequest() -> CompleteContractRequest {
        CompleteContractRequest(
            title: trimmedTitle, goal: effectiveGoal, details: Self.nonEmpty(details), criteria: criteria,
            workReference: Self.nonEmpty(workReference))
    }
}

/// The Add task form: Save task sends Add task and then Complete contract, each
/// under its own key (MA-13, SM-4).
///
/// A key is kept while its command has not been answered, so pressing Save task
/// again sends the same command and a repeat writes nothing twice; it is dropped
/// when the form changes, because the server refuses one key with two bodies. If
/// Add task worked and Complete contract did not, the task is in Backlog: the
/// next press sends only Complete contract, to that task (MA-16).
@MainActor
@Observable
final class AddTaskModel {
    enum State: Equatable, Sendable {
        case editing
        case saving
        case saved
        case failed(ShellCopy)
    }

    private(set) var state: State = .editing

    var draft = ContractDraft() {
        didSet {
            guard draft != oldValue else { return }
            addKey = nil
            completeKey = nil
            ideaKey = nil
        }
    }

    var title: String {
        get { draft.title }
        set { draft.title = newValue }
    }
    var goal: String {
        get { draft.goal }
        set { draft.goal = newValue }
    }
    var details: String {
        get { draft.details }
        set { draft.details = newValue }
    }
    var criteriaText: String {
        get { draft.criteriaText }
        set { draft.criteriaText = newValue }
    }
    var priority: Priority {
        get { draft.priority }
        set { draft.priority = newValue }
    }
    var workReference: String {
        get { draft.workReference }
        set { draft.workReference = newValue }
    }

    @ObservationIgnored private let api: any OwnerAPI
    @ObservationIgnored private let onSaved: @MainActor () -> Void
    @ObservationIgnored private var addKey: IdempotencyKey?
    @ObservationIgnored private var completeKey: IdempotencyKey?
    @ObservationIgnored private var ideaKey: IdempotencyKey?
    @ObservationIgnored private var createdTaskID: UUID?

    init(api: any OwnerAPI, onSaved: @escaping @MainActor () -> Void) {
        self.api = api
        self.onSaved = onSaved
    }

    var isBusy: Bool { state == .saving }

    /// Whether Save task is on: there is a title and nothing is being sent.
    var canSave: Bool {
        !isBusy && state != .saved && !draft.trimmedTitle.isEmpty
    }

    /// The failure line, if the last try did not work.
    var failure: ShellCopy? {
        if case .failed(let copy) = state { copy } else { nil }
    }

    /// The task was added to Backlog but its contract was not sent.
    var savedWithoutContract: Bool {
        if case .failed = state { createdTaskID != nil } else { false }
    }

    /// Whether Save as an idea is on: there is a title, nothing is being sent,
    /// and Save task has not already added this task to Backlog.
    var canSaveAsIdea: Bool { canSave && createdTaskID == nil }

    /// Whether the criteria typed would be left out of an idea (HM-48).
    var ideaDropsCriteria: Bool { draft.hasTypedCriteria }

    /// Save as an idea: Add task alone, into the Imaginarium (HM-48).
    func saveAsIdea() async {
        guard canSaveAsIdea else { return }
        state = .saving
        do {
            let key = ideaKey ?? IdempotencyKey()
            ideaKey = key
            let outcome = try await api.addTask(draft.ideaRequest(), key: key)
            guard try outcome.completedResult() != nil else { throw LeverageClientError.invalidBody }
            state = .saved
            onSaved()
        } catch {
            state = .failed(ShellCopy.sentence(for: error))
        }
    }

    /// Sends Add task and then Complete contract.
    func save() async {
        guard canSave else { return }
        state = .saving
        do {
            if createdTaskID == nil {
                let key = addKey ?? IdempotencyKey()
                addKey = key
                let outcome = try await api.addTask(draft.addRequest(), key: key)
                guard let created = try outcome.completedResult() else { throw LeverageClientError.invalidBody }
                createdTaskID = created.taskID
            }
            guard let taskID = createdTaskID else { return }
            let key = completeKey ?? IdempotencyKey()
            completeKey = key
            _ = try await api.completeContract(taskID: taskID, draft.completeRequest(), key: key).completedResult()
            state = .saved
            onSaved()
        } catch {
            state = .failed(ShellCopy.sentence(for: error))
        }
    }
}
