import Foundation
import Testing

@testable import LeverageApp

/// The tabs of the left pane: Settings joins them last (RD-25).
@MainActor
@Suite("SidePane")
struct SidePaneTests {
    @Test("the pane lists the six tabs in order, with Settings last")
    func tabsInOrder() {
        #expect(SidePane.tabs.map(\.place) == [.board, .needsYou, .agents, .credentials, .handoff, .settings])
        #expect(SidePane.tabs.map(\.copy.text) == [
            "Board", "Needs you", "Agents", "Credentials", "Handoff", "Settings",
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
}
