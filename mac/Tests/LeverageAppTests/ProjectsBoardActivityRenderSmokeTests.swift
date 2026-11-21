import Foundation
import LeverageKit
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

    @Test("project details, Activity rows and the Add task fields draw with content")
    func populatedScreensDraw() async {
        let owner = FakeOwnerAPI()
        let project = Project(id: UUID(), name: "Example project", goal: "Prepare the example", budget: 12, briefVersion: 0)
        let task = TaskSummary(id: UUID(), title: "Example task", goal: "Prepare the example", state: .ready)
        let event = EventRecord(
            id: UUID(), workspaceID: UUID(), seq: 1, at: Date(),
            type: .taskCreated, actorKind: .owner, taskID: task.id)
        owner.script {
            $0.listProjects = { ProjectsList(projects: [project]) }
            $0.board = { Board(tasks: [BoardTask(task: task)], asOfSeq: 1, reviewerSeatExists: false) }
            $0.seats = { SeatsList(seats: [], asOfSeq: 1) }
            $0.events = { _, _, _ in EventsPage(events: [event], nextAfterSeq: 1) }
        }

        let projects = ProjectsModel(api: owner)
        await projects.load()
        #expect(projects.projects.count == 1)
        #expect(AgentFixtures.draws(ProjectsContent(model: projects).background(.white)))
        let detail = ProjectDetailModel(projectID: project.id, projects: projects)
        #expect(AgentFixtures.draws(ProjectDetailView(model: detail, back: {}).background(.white)))

        let activity = ActivityModel(api: owner)
        await activity.load()
        #expect(activity.entries.count == 1)
        #expect(AgentFixtures.draws(ActivityContent(model: activity).background(.white)))

        let add = AddTaskModel(api: owner, boardFilter: BoardFilter(projectID: project.id), onSaved: {})
        add.title = task.title
        add.actions = [OutwardActionDraft(kind: .publish, description: "Publish the example")]
        #expect(AgentFixtures.draws(AddTaskForm(model: add, projects: [project], cancel: {}), height: 800))
    }
}
