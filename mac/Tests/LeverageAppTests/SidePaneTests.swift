import Foundation
import LeverageKit
import LeverageTestSupport
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
            "Task board", "Needs you", "Decided for you", "Activity", "Agents", "Credentials", "Handoff", "Settings",
        ])
        #expect(Set(SidePane.tabs.map(\.symbol)).count == SidePane.tabs.count)
        #expect(SidePane.tabs.allSatisfy { !$0.symbol.isEmpty })
    }

    @Test("the Imaginarium project is listed first, and the other projects keep their order")
    func imaginariumProjectFirst() {
        let first = Project(id: UUID(), name: "Invoices", goal: "", briefVersion: 0)
        let imaginarium = Project(id: UUID(), name: "Imaginarium", imaginarium: true, goal: "", briefVersion: 0)
        let second = Project(id: UUID(), name: "Reports", goal: "", briefVersion: 0)
        let third = Project(id: UUID(), name: "Archive", goal: "", briefVersion: 0)

        let listed = SidePane.orderedProjects([first, second, imaginarium, third])

        #expect(listed.map(\.id) == [imaginarium.id, first.id, second.id, third.id])
    }

    @Test("without an Imaginarium project the list keeps its order")
    func projectOrderWithoutImaginarium() {
        let first = Project(id: UUID(), name: "Invoices", goal: "", briefVersion: 0)
        let second = Project(id: UUID(), name: "Reports", goal: "", briefVersion: 0)

        #expect(SidePane.orderedProjects([second, first]).map(\.id) == [second.id, first.id])
    }

    @Test("the setup spotlight can light the Credentials and Agents tabs, and no other")
    func spotlightTabs() {
        #expect(SidePane.spotlightTarget(for: .credentials) == .credentialsTab)
        #expect(SidePane.spotlightTarget(for: .agents) == .agentsTab)
        for tab in SidePane.tabs where tab.place != .credentials && tab.place != .agents {
            #expect(SidePane.spotlightTarget(for: tab.place) == nil, "\(tab.place)")
        }
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

    @Test("task changes refresh the project work reference for the next Add task", arguments: [
        EventType.taskCreated, .taskChanged, .taskContractChanged, .taskSubmitted, .contentDeleted,
    ])
    func refreshesWorkReference(eventType: EventType) async throws {
        let rig = ShellRig()
        let owner = rig.owner
        let projectID = UUID()
        let actor: ActorKind = eventType == .taskSubmitted ? .seat : .owner
        let event = EventRecord(
            id: UUID(), workspaceID: UUID(), seq: 3, at: Date(), type: eventType, actorKind: actor, taskID: UUID())
        let latest = Locked<String?>("~/work/first")
        let deliver = Locked(false)
        owner.script {
            $0.listProjects = {
                ProjectsList(projects: [Project(
                    id: projectID, name: "Example project", goal: "", briefVersion: 0,
                    latestWorkReference: latest.value)])
            }
            $0.seats = { SeatsList(seats: [], asOfSeq: 2) }
            $0.events = { after, _, _ in
                if after == 2, deliver.value { return EventsPage(events: [event], nextAfterSeq: event.seq) }
                try await Task.sleep(for: .milliseconds(10))
                return EventsPage(events: [], nextAfterSeq: after)
            }
        }
        let feed = EventFeed(owner: owner)
        let context = ScreenContext(
            owner: owner, feed: feed, health: HealthLineModel(owner: owner, helper: rig.runtime.helper),
            runtime: rig.runtime)
        let watch = Task { await context.watchProjects() }
        defer {
            watch.cancel()
            feed.stop()
        }
        try #require(await ShellFixtures.eventually(timeout: .seconds(30)) {
            context.paneProjects.first?.latestWorkReference == "~/work/first"
        })

        let changed = eventType == .contentDeleted ? nil : "~/work/second"
        latest.value = changed
        deliver.value = true
        #expect(await ShellFixtures.eventually(timeout: .seconds(30)) {
            context.paneProjects.first?.latestWorkReference == changed
        })

        let form = AddTaskModel(api: owner, onSaved: {})
        form.updateProjects(context.paneProjects)
        form.projectID = projectID
        #expect(form.workReference == (changed ?? ""))
    }

    @Test("the pane's projects read and the owner's action calls observe session expiry")
    func newCallsObserveSessionExpiry() async {
        let base = FakeOwnerAPI()
        let expired = TransportError(code: .unauthenticated, message: "made-up expiry")
        base.script {
            $0.listProjects = { throw expired }
            $0.waiveAction = { _, _ in throw expired }
        }
        var notifications = 0
        let owner: any OwnerAPI = SessionGuard(base: base, onUnauthenticated: { notifications += 1 })
        let actionID = UUID()
        let key = IdempotencyKey()

        await #expect(throws: expired) { try await owner.listProjects() }
        await #expect(throws: expired) { try await owner.waiveAction(actionID: actionID, key: key) }

        #expect(notifications == 2)
        #expect(base.calls == [
            FakeCall(.listProjects),
            FakeCall(.waiveAction, path: ["id": actionID.contractString], key: key),
        ])
    }
}
