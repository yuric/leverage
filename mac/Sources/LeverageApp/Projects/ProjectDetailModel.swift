import Foundation
import LeverageKit
import Observation

@MainActor
@Observable
final class ProjectDetailModel {
    private let projectID: UUID
    private let projects: ProjectsModel

    init(projectID: UUID, projects: ProjectsModel) {
        self.projectID = projectID
        self.projects = projects
    }

    var project: Project? { projects.projects.first { $0.id == projectID } }
    var isPaused: Bool { project?.paused == true }
    var isSaving: Bool { projects.isSaving }
    var failure: ShellCopy? { projects.failure }

    var budgetText: String {
        project?.budget.map(dollars) ?? ProjectsCopy.noLimit.text
    }

    var spentText: String {
        guard let project else { return "" }
        return ProjectsCopy.reported.filled(["amount": dollars(project.spent)])
    }

    var budgetInput: String {
        SpendingAmount.fieldText(project?.budget, locale: projects.locale)
    }

    /// The server refuses to delete the Imaginarium project's content: the
    /// gallery sends every task there and nothing creates another.
    var canDeleteContent: Bool {
        guard let project else { return false }
        return !project.imaginarium && project.contentDeletedAt == nil && project.openTasks == 0
    }

    func clearFailure() { projects.clearFailure() }

    func setPaused(_ paused: Bool) async {
        guard let project, project.contentDeletedAt == nil, project.paused != paused else { return }
        _ = await projects.save(paused ? .pause(projectID) : .resume(projectID))
    }

    func canChangeBudget(_ input: String) -> Bool {
        guard let request = projects.budgetRequest(input), !isSaving else { return false }
        return input != budgetInput && request.budget != project?.budget
    }

    func changeBudget(_ input: String) async -> Bool {
        guard let project, project.contentDeletedAt == nil, let request = projects.budgetRequest(input) else {
            return false
        }
        return await projects.save(.changeBudget(projectID, request))
    }

    func saveBrief(_ editor: BriefEditorModel) async -> Bool {
        guard let project, project.contentDeletedAt == nil, let request = editor.request else { return false }
        return await projects.save(.editBrief(projectID, request))
    }

    func deleteContent() async -> Bool {
        guard canDeleteContent else { return false }
        return await projects.save(.deleteContent(projectID))
    }

    private func dollars(_ value: Decimal) -> String {
        value.formatted(.currency(code: "USD").precision(.fractionLength(2)).locale(projects.locale))
    }
}
