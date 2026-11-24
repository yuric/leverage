import Foundation
import LeverageKit
import Observation

/// What the owner typed into the form: the values of Add task and of
/// Complete contract, which sends the same values again (IN-20). Shared by the
/// Add task sheet and by the form on a Backlog task's page (MA-16).
struct ContractDraft: Equatable, Sendable {
    var title = ""
    var details = ""
    /// One criterion on each line.
    var criteriaText = ""
    var actions: [OutwardActionDraft] = []
    var priority: Priority = .normal
    var workReference = ""
    /// The words of the independent review. A task that has one keeps its own
    /// words when the owner changes the task (HM-49).
    var reviewCriterionText = AddTaskCopy.reviewCriterion.text

    var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Preserve the original formatting, including in details folded on upgrade.
    private var detailsInput: String? { Self.nonEmpty(details) == nil ? nil : details }

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

    private var actionInputs: [ActionInput] {
        actions.map { ActionInput(kind: $0.kind, description: $0.description) }
    }

    /// Add task: keep the details even if Complete contract has yet to run.
    /// Criteria go with Complete contract.
    func addRequest(projectID: UUID?, state: TaskState = .backlog) -> AddTaskRequest {
        AddTaskRequest(
            title: trimmedTitle, details: detailsInput, actions: actions.isEmpty ? nil : actionInputs,
            projectID: projectID, priority: priority, workReference: Self.nonEmpty(workReference), state: state)
    }

    /// Whether the owner typed criteria, which an idea does not keep.
    var hasTypedCriteria: Bool {
        criteriaText.split(whereSeparator: \.isNewline).contains { Self.nonEmpty(String($0)) != nil }
    }

    /// Complete contract: every field, the form's values sent again.
    func completeRequest() -> CompleteContractRequest {
        CompleteContractRequest(
            title: trimmedTitle, details: detailsInput, criteria: criteria,
            actions: actionInputs, workReference: Self.nonEmpty(workReference))
    }
}

struct OutwardActionDraft: Equatable, Identifiable, Sendable {
    let id = UUID()
    var kind: ActionKind = .publish
    var description = ""
}

struct AddTaskProjectChoice: Equatable, Identifiable {
    let id: UUID?
    let name: String
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

    private var draft = ContractDraft() {
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
        set {
            workReferenceSource = .owner
            draft.workReference = newValue
        }
    }

    @ObservationIgnored private let api: any OwnerAPI
    @ObservationIgnored private let onSaved: @MainActor () -> Void
    @ObservationIgnored private var addKey: IdempotencyKey?
    @ObservationIgnored private var completeKey: IdempotencyKey?
    @ObservationIgnored private var ideaKey: IdempotencyKey?
    @ObservationIgnored private var createdTaskID: UUID?
    @ObservationIgnored private var rulesRead = false

    /// The keys of the two shipped rules the form's words follow.
    private static let acceptanceCriteriaKey = "acceptance_criteria"
    private static let providerRuleKey = "different_provider_review"

    private(set) var acceptanceCriteriaRuleOn = false
    private(set) var providerRuleOn = false

    private var selectedProjectID: UUID?
    @ObservationIgnored private var projects: [Project] = []

    private enum WorkReferenceSource {
        case empty, project, owner
    }

    @ObservationIgnored private var workReferenceSource: WorkReferenceSource = .empty

    var projectID: UUID? {
        get { selectedProjectID }
        set {
            guard canChooseProject, newValue != selectedProjectID else { return }
            selectedProjectID = newValue
            addKey = nil
            ideaKey = nil
            if workReferenceSource == .project || workReference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                fillProjectWorkReference()
            }
        }
    }

    var actions: [OutwardActionDraft] {
        get { draft.actions }
        set { draft.actions = newValue }
    }

    init(api: any OwnerAPI, boardFilter: BoardFilter = BoardFilter(), onSaved: @escaping @MainActor () -> Void) {
        self.api = api
        self.onSaved = onSaved
        selectedProjectID = boardFilter.projectID
    }

    /// After Add task creates the Backlog task, a retry only completes its contract.
    var canChooseProject: Bool { !isBusy && state != .saved && createdTaskID == nil }

    /// A project selected on the board can be known before its metadata arrives.
    func updateProjects(_ projects: [Project]) {
        self.projects = projects
        if canChooseProject, selectedProjectID != nil, workReferenceSource == .empty {
            fillProjectWorkReference()
        }
    }

    private func fillProjectWorkReference() {
        let project = projects.first { $0.id == selectedProjectID && $0.contentDeletedAt == nil }
        let reference = project?.latestWorkReference ?? ""
        let isEmpty = reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        draft.workReference = isEmpty ? "" : reference
        workReferenceSource = isEmpty ? .empty : .project
    }

    func projectChoices(_ projects: [Project]) -> [AddTaskProjectChoice] {
        var choices = [AddTaskProjectChoice(id: nil, name: AddTaskCopy.noProject.text)]
        choices += projects.map { AddTaskProjectChoice(id: $0.id, name: ProjectsCopy.projectName($0)) }
        if let projectID, !projects.contains(where: { $0.id == projectID }) {
            choices.append(AddTaskProjectChoice(id: projectID, name: BoardCopy.selectedProject.text))
        }
        return choices
    }

    func addAction() {
        actions.append(OutwardActionDraft())
    }

    func removeAction(id: UUID) {
        actions.removeAll { $0.id == id }
    }

    var hasIncompleteActions: Bool {
        actions.contains { $0.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var isBusy: Bool { state == .saving }

    /// Whether the form is ready to save.
    var canSave: Bool {
        !isBusy && state != .saved && !draft.trimmedTitle.isEmpty && !hasIncompleteActions
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

    /// Reads the rules once when the form opens, for its hint and its footnote
    /// (RM-3). The words are a nicety: a list that cannot be read leaves them as
    /// milestone 2 had them, and the form works all the same.
    func loadRules() async {
        guard !rulesRead else { return }
        rulesRead = true
        guard let list = try? await api.listRules() else { return }
        acceptanceCriteriaRuleOn = list.rules.contains { $0.rule.key == Self.acceptanceCriteriaKey && $0.rule.enabled }
        providerRuleOn = list.rules.contains { $0.rule.key == Self.providerRuleKey && $0.rule.enabled }
    }

    /// The line under the criteria: while the acceptance-criteria rule is on it
    /// says an empty task waits in Backlog (RD-27).
    var criteriaHint: AddTaskCopy { acceptanceCriteriaRuleOn ? .criteriaHintRuleOn : .criteriaHint }

    /// The line under the form: while the provider rule is on it says another
    /// provider reviews (RD-27).
    var footnote: AddTaskCopy { providerRuleOn ? .footnoteProviderRule : .footnote }

    /// Whether the criteria typed would be left out of an idea (HM-48).
    var ideaDropsCriteria: Bool { draft.hasTypedCriteria }

    /// Save as an idea: Add task alone, into the Imaginarium (HM-48).
    func saveAsIdea() async {
        guard canSaveAsIdea else { return }
        state = .saving
        do {
            let key = ideaKey ?? IdempotencyKey()
            ideaKey = key
            let outcome = try await api.addTask(draft.addRequest(projectID: projectID, state: .imaginarium), key: key)
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
                let outcome = try await api.addTask(draft.addRequest(projectID: projectID), key: key)
                guard let created = try outcome.completedResult() else { throw LeverageClientError.invalidBody }
                createdTaskID = created.taskID
            }
            guard let taskID = createdTaskID else { return }
            let key = completeKey ?? IdempotencyKey()
            completeKey = key
            try await api.completeContract(taskID: taskID, draft.completeRequest(), key: key).acceptedWhilePending()
            state = .saved
            onSaved()
        } catch {
            state = .failed(ShellCopy.sentence(for: error))
        }
    }
}

extension CommandOutcome {
    /// Whether the server took the command: completed, or still waiting for the
    /// checks of a rule, which is not a failure (RD-27). A refusal throws.
    func acceptedWhilePending() throws {
        if outcome == .pending { return }
        _ = try completedResult()
    }
}
