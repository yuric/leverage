import Foundation
import Testing

@testable import LeverageApp

/// The left pane's destinations and project choices (AP-30).
@MainActor
@Suite("SidePane")
struct SidePaneTests {
    @Test("the pane lists the tabs in order, with Settings last")
    func tabsInOrder() {
        #expect(SidePane.tabs.map(\.place) == [
            .board, .needsYou, .decided, .activity, .agents, .credentials, .handoff, .settings,
        ])
        #expect(SidePane.tabs.map(\.copy.text) == [
            "Board", "Needs you", "Decided for you", "Activity", "Agents", "Credentials", "Handoff", "Settings",
        ])
        #expect(Set(SidePane.tabs.map(\.symbol)).count == SidePane.tabs.count)
        #expect(SidePane.tabs.allSatisfy { !$0.symbol.isEmpty })
    }

    @Test("showing Settings leaves a task's page and shows Settings")
    func showsSettings() {
        let navigator = Navigator()
        navigator.open(task: UUID())
        navigator.show(.settings)
        #expect(navigator.place == .settings)
        #expect(navigator.openTaskID == nil)
    }

    @Test("choosing a project sets the project filter and opens the Board")
    func choosesProject() {
        let navigator = Navigator()
        let projectID = UUID()
        let agentID = UUID()
        navigator.boardFilter.agentID = agentID
        navigator.show(.needsYou)

        navigator.selectProject(projectID)

        #expect(navigator.place == .board)
        #expect(navigator.boardFilter.projectID == projectID)
        #expect(navigator.boardFilter.agentID == agentID)
    }

    @Test("All projects clears the project filter and returns from a task to the Board")
    func choosesAllProjects() {
        let navigator = Navigator()
        navigator.boardFilter.projectID = UUID()
        navigator.open(task: UUID(), editing: true)

        navigator.selectProject(nil)

        #expect(navigator.place == .board)
        #expect(navigator.openTaskID == nil)
        #expect(navigator.boardFilter.projectID == nil)
    }
}
