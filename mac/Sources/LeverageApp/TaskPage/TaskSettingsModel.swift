import Foundation
import LeverageKit
import Observation

@MainActor
@Observable
final class TaskSettingsModel {
    var priority: Priority
    var projectID: UUID?
    var capText = ""

    init(task: TaskSummary, api: any OwnerAPI, didChange: @escaping @MainActor () -> Void) {
        priority = task.priority
        projectID = task.projectID
    }

    var canSave: Bool { false }

    func save() async -> Bool { false }
}
