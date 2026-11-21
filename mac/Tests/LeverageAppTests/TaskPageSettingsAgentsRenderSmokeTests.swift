import Foundation
import LeverageKit
import LeverageTestSupport
import SwiftUI
import Testing

@testable import LeverageApp

@MainActor
@Suite("Task page, Settings and Agents render smoke")
struct TaskPageSettingsAgentsRenderSmokeTests {
    @Test("The task page, its questions and actions, and its settings draw")
    func taskPage() async throws {
        let task = TaskSummary(
            id: UUID(), title: "Prepare the preview", goal: "Check the changes", state: .finishing, budgetCap: 10)
        let question = Question(
            id: UUID(), taskID: task.id, askingSeatID: AgentFixtures.builderID, text: "Which preview?",
            assumption: "", blocking: false, outcome: .answered, answer: "The second one",
            basis: .owner, answeredByKind: .owner)
        let action = OutwardAction(
            id: UUID(), taskID: task.id, kind: .publish, description: "Example preview", state: .started,
            approvedByKind: .owner)
        let page = TaskPage(
            task: task, actions: [action], questions: [question], reviewerSeatExists: true, asOfSeq: 10,
            anyActionStarted: true)
        let owner = FakeOwnerAPI()
        owner.script { $0.task = { _ in page } }
        let model = TaskPageModel(taskID: task.id, api: owner, noteRead: { _ in })
        await model.load()
        #expect(AgentFixtures.draws(TaskPageBody(model: model), height: 850))
        #expect(AgentFixtures.draws(QuestionsSection(rows: model.questions), height: 135))
        #expect(AgentFixtures.draws(ActionsSection(rows: model.actions), height: 135))
        model.beginChangingSettings()
        let settings = try #require(model.settings)
        let sheet = TaskSettingsSheet(model: settings, projects: [], dismiss: {})
        #expect(AgentFixtures.draws(sheet, width: 430, height: 290))
        #expect(AgentFixtures.draws(sheet.environment(\.colorScheme, .dark), width: 430, height: 290))
    }

    @Test("Workspace settings and the new rule scopes draw")
    func settings() async {
        let owner = FakeOwnerAPI()
        let initial = WorkspaceSettings(
            leaseLengthSeconds: 600, checkQueueTimeoutSeconds: 90, checkRunTimeoutSeconds: 120,
            maximumRounds: 3, rerunLimit: 3)
        owner.script { $0.workspaceSettings = { initial } }
        let settings = WorkspaceSettingsModel(api: owner)
        await settings.load()
        let content = WorkspaceSettingsContent(model: settings)
        #expect(AgentFixtures.draws(content))
        #expect(AgentFixtures.draws(content.environment(\.colorScheme, .dark)))

        let editor = RuleEditorModel(mode: .add, api: owner, onDone: {})
        editor.hook = .actionRequested
        let project = Project(id: UUID(), name: "Sample", goal: "Review the preview", briefVersion: 0)
        editor.scopeKind = .namedProjects
        #expect(AgentFixtures.draws(RuleEditorSheet(model: editor, cancel: {}, projects: [project]), height: 620))
        editor.scopeKind = .actionKinds
        #expect(AgentFixtures.draws(RuleEditorSheet(model: editor, cancel: {}).environment(\.colorScheme, .dark)))
    }

    @Test("The connection picker, MCP setup and Change strength sheet draw")
    func agents() async {
        let owner = AgentFixtures.owner()
        owner.script {
            $0.connectSeat = { _, key in
                .completed(.shown(SeatConnected(seatID: AgentFixtures.ownID, seatToken: AgentFixtures.madeUpToken)),
                           key: key.value, command: .connectSeat)
            }
            $0.landingPromptForConnection = { _, connection in
                LandingPrompt(text: "Start with get_next.", connection: connection)
            }
        }
        let connect = ConnectAgentModel(
            api: owner, copy: { _ in }, onConnected: {}, apiURL: { URL(string: "http://127.0.0.1:49170") })
        connect.mode = .connectsOnItsOwn
        connect.connection = .mcp
        connect.name = "Example agent"
        let form = ConnectAgentForm(model: connect, cancel: {}, addLogin: {})
        #expect(AgentFixtures.draws(form, width: 600, height: 820))
        await connect.connect()
        #expect(connect.mcpSettings != nil)
        #expect(AgentFixtures.draws(form.environment(\.colorScheme, .dark), width: 600, height: 820))

        let change = ChangeAgentModel(
            api: owner, seat: AgentFixtures.seat(AgentFixtures.ownID, name: "Example agent", strengthRank: 2),
            logins: [], onChanged: {})
        #expect(AgentFixtures.draws(ChangeAgentForm(model: change, cancel: {}), width: 580, height: 540))
        connect.finish()
    }
}
