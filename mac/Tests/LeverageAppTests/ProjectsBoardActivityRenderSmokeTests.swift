import Foundation
import LeverageTestSupport
import SwiftUI
import Testing

@testable import LeverageApp

@MainActor
@Suite("Projects, Board and Activity render smoke")
struct ProjectsBoardActivityRenderSmokeTests {
    @Test("Projects, Board and Activity draw through the shell environment")
    func screensDraw() {
        let rig = ShellRig()
        let context = ScreenContext(
            owner: rig.owner,
            feed: EventFeed(owner: rig.owner),
            health: HealthLineModel(owner: rig.owner, helper: rig.runtime.helper),
            runtime: rig.runtime)
        #expect(AgentFixtures.draws(ProjectsView().environment(context).background(.white)))
        #expect(AgentFixtures.draws(BoardView().environment(context).background(.white)))
        #expect(AgentFixtures.draws(ActivityView().environment(context).background(.white)))
    }
}
