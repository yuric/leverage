import Foundation
import LeverageKit

@MainActor
final class ProjectsModel {
    var projects: [Project] { [] }
    var failure: ShellCopy? { nil }

    init(api: any OwnerAPI, locale: Locale = .current) {}

    func load() async {}
    func watch(_ feed: EventFeed) async {}
    func create(name: String, goal: String, budget: String) async -> Bool { false }
}
