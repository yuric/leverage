import Foundation
import LeverageKit
import LeverageTestSupport
import Testing

@testable import LeverageApp

@MainActor
@Suite("Projects")
struct ProjectsModelTests {
    nonisolated private static let projectID = UUID()

    nonisolated private static func project(
        budget: Decimal? = 20, spent: Decimal = 2.5, paused: Bool = false,
        openTasks: Int = 0, deleted: Bool = false, brief: [BriefEntry] = []
    ) -> Project {
        Project(
            id: projectID, name: deleted ? "" : "Sample project", goal: "Collect examples",
            budget: budget, spent: spent, paused: paused, briefVersion: 1, brief: brief,
            pausedBy: paused ? .owner : nil, openTasks: openTasks, contentDeletedAt: deleted ? Date() : nil)
    }

    private static func briefEntry(_ text: String, kind: BriefEntryKind) -> BriefEntry {
        BriefEntry(id: UUID(), projectID: projectID, kind: kind, text: text, authorKind: .owner, authorID: nil)
    }

    private func model(startingWith rows: [Project]) -> (FakeOwnerAPI, Locked<[Project]>, ProjectsModel) {
        let owner = FakeOwnerAPI()
        let projects = Locked(rows)
        owner.script { $0.listProjects = { ProjectsList(projects: projects.value) } }
        return (owner, projects, ProjectsModel(api: owner, locale: Locale(identifier: "en_US")))
    }

    @Test("the list comes from the owner read and a new project refreshes it")
    func listAndCreate() async throws {
        let (owner, projects, model) = model(startingWith: [])
        await model.load()
        #expect(model.projects.isEmpty)
        let added = Self.project()
        owner.script {
            $0.createProject = { _, key in
                projects.value = [added]
                return .completed(nil, key: key.value, command: .createProject)
            }
        }

        #expect(!(await model.create(name: " ", goal: "", budget: "")))
        #expect(!(await model.create(name: "Sample project", goal: "", budget: "20.00 extra")))
        #expect(await model.create(name: "Sample project", goal: "Collect examples", budget: "20.00"))
        #expect(model.projects == [added])
        let calls = owner.calls.filter { $0.operation == .createProject }
        try #require(calls.count == 1)
        #expect(calls[0].body == FakeCall.json(CreateProjectRequest(name: added.name, goal: added.goal, budget: 20)))
        #expect(calls[0].key != nil)
    }

    @Test("changing a brief replaces the whole list in the order it is edited")
    func savesWholeBrief() async throws {
        let brief = [Self.briefEntry("Old rule", kind: .rule), Self.briefEntry("Keep this", kind: .lesson)]
        let (owner, _, projects) = model(startingWith: [Self.project(brief: brief)])
        owner.script {
            $0.editBrief = { _, _, key in .completed(nil, key: key.value, command: .editBrief) }
        }
        await projects.load()
        let detail = ProjectDetailModel(projectID: Self.projectID, projects: projects)
        let editor = BriefEditorModel(brief: brief)
        #expect(editor.entries.map(\.text) == ["Old rule", "Keep this"])
        try #require(editor.entries.count == 2)
        editor.entries.removeFirst()
        editor.entries.append(.init(kind: .decision, text: "A new decision"))

        #expect(await detail.saveBrief(editor))
        let call = try #require(owner.calls.first { $0.operation == .editBrief })
        #expect(call.path["id"] == Self.projectID.uuidString.lowercased())
        #expect(call.body == FakeCall.json(EditBriefRequest(entries: [
            BriefEntryInput(kind: .lesson, text: "Keep this"), BriefEntryInput(kind: .decision, text: "A new decision"),
        ])))

        editor.entries.removeAll()
        #expect(await detail.saveBrief(editor))
        #expect(owner.calls.last { $0.operation == .editBrief }?.body == FakeCall.json(EditBriefRequest(entries: [])))
    }

    @Test("budget and reported spend are in US dollars, and an empty budget clears the limit")
    func budgetAndReportedSpend() async throws {
        let (owner, rows, projects) = model(startingWith: [Self.project()])
        owner.script {
            $0.changeBudget = { _, request, key in
                rows.value = [Self.project(budget: request.budget)]
                return .completed(nil, key: key.value, command: .changeBudget)
            }
        }
        await projects.load()
        let detail = ProjectDetailModel(projectID: Self.projectID, projects: projects)
        #expect(detail.budgetText == "$20.00")
        #expect(detail.spentText == "$2.50 reported")
        #expect(!(await detail.changeBudget("-2")))
        #expect(await detail.changeBudget("37.50"))
        #expect(detail.budgetText == "$37.50")
        #expect(await detail.changeBudget(""))
        #expect(detail.budgetText == "No limit")
        let calls = owner.calls.filter { $0.operation == .changeBudget }
        try #require(calls.count == 2)
        #expect(calls[0].body == FakeCall.json(ChangeBudgetRequest(budget: 37.5)))
        #expect(calls[1].body == .object(["budget": .null]))
    }

    @Test("project budgets accept the local decimal separator within the stored range")
    func localizedBudgetRange() {
        let model = ProjectsModel(api: FakeOwnerAPI(), locale: Locale(identifier: "de_DE"))
        #expect(model.budgetRequest("99999999,99")?.budget == Decimal(string: "99999999.99"))
        for invalid in ["100000000,00", "12.50", "12,505"] {
            #expect(model.budgetRequest(invalid) == nil)
        }
    }

    @Test("project delete confirmation accounts for backups")
    func deleteCopy() {
        #expect(ProjectsCopy.deleteExplanation.text.contains("Backups"))
    }

    @Test("pause and resume send the matching command and refresh the project")
    func pauseAndResume() async {
        let (owner, rows, projects) = model(startingWith: [Self.project()])
        owner.script {
            $0.pauseProject = { _, key in
                rows.value = [Self.project(paused: true)]
                return .completed(nil, key: key.value, command: .pauseProject)
            }
            $0.resumeProject = { _, key in
                rows.value = [Self.project()]
                return .completed(nil, key: key.value, command: .resumeProject)
            }
        }
        await projects.load()
        let detail = ProjectDetailModel(projectID: Self.projectID, projects: projects)
        await detail.setPaused(true)
        #expect(detail.isPaused)
        await detail.setPaused(false)
        #expect(!detail.isPaused)
        #expect(owner.calls.filter { [.pauseProject, .resumeProject].contains($0.operation) }.map(\.operation)
            == [.pauseProject, .resumeProject])
    }

    @Test("deletion is available only when no task is open and only before deletion")
    func deleteContent() async {
        let (owner, rows, projects) = model(startingWith: [Self.project(openTasks: 1)])
        owner.script {
            $0.deleteProjectContent = { _, key in
                rows.value = [Self.project(deleted: true)]
                return .completed(nil, key: key.value, command: .deleteContent)
            }
        }
        await projects.load()
        let detail = ProjectDetailModel(projectID: Self.projectID, projects: projects)
        #expect(!detail.canDeleteContent)
        #expect(!(await detail.deleteContent()))
        #expect(owner.calls.allSatisfy { $0.operation != .deleteProjectContent })
        rows.value = [Self.project()]
        await projects.load()
        #expect(detail.canDeleteContent)
        #expect(await detail.deleteContent())
        #expect(!detail.canDeleteContent)
        #expect(!(await detail.deleteContent()))
        #expect(owner.calls.filter { $0.operation == .deleteProjectContent }.count == 1)
    }

    @Test("a project or task update on the shared feed refreshes the list")
    func followsFeed() async {
        let (owner, rows, projects) = model(startingWith: [Self.project(openTasks: 1)])
        let sent = Locked(false)
        owner.script {
            $0.seats = { SeatsList(seats: [], asOfSeq: 2) }
            $0.events = { after, _, _ in
                if after == 2, sent.value {
                    let event = EventRecord(
                        id: UUID(), workspaceID: UUID(), seq: 3, at: Date(), type: .taskDone, actorKind: .owner)
                    return EventsPage(events: [event], nextAfterSeq: 3)
                }
                try await Task.sleep(for: .milliseconds(10))
                return EventsPage(events: [], nextAfterSeq: after)
            }
        }
        let feed = EventFeed(owner: owner)
        let watch = Task { await projects.watch(feed) }
        defer {
            watch.cancel()
            feed.stop()
        }
        guard await ShellFixtures.eventually(timeout: .seconds(1), { projects.projects.first?.openTasks == 1 }) else {
            Issue.record("The first project read did not show the open task.")
            return
        }
        rows.value = [Self.project()]
        sent.value = true
        #expect(await ShellFixtures.eventually(timeout: .seconds(1)) { projects.projects.first?.openTasks == 0 })
    }
}
