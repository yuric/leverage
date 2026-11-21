import Foundation
import LeverageKit

@MainActor
final class ProjectDetailModel {
    var budgetText: String { "" }
    var spentText: String { "" }
    var canDeleteContent: Bool { false }
    var isPaused: Bool { false }

    init(projectID: UUID, projects: ProjectsModel) {}

    func setPaused(_ paused: Bool) async {}
    func changeBudget(_ text: String) async -> Bool { false }
    func saveBrief(_ editor: BriefEditorModel) async -> Bool { false }
    func deleteContent() async -> Bool { false }
}
