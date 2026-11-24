import Foundation
import LeverageTestSupport
import Testing
@testable import LeverageKit

@Suite("Questions and approvals client calls")
struct QuestionsAndApprovalsClientTests {
    private static let taskID = UUID(uuidString: "00000000-0000-4000-8000-0000000000A1")!
    private static let relatedID = UUID(uuidString: "00000000-0000-4000-8000-0000000000B2")!
    private static let key = IdempotencyKey("made-up-questions-and-approvals-key")!
    private static let bearer = "made-up-api-token"

    enum Call: Sendable {
        case agent(String, @Sendable (AgentClient) async throws -> Void)
        case owner(String, @Sendable (OwnerClient) async throws -> Void)

        var operation: String {
            switch self {
            case .agent(let operation, _), .owner(let operation, _): operation
            }
        }

        func send(through transport: HTTPTransport) async throws {
            switch self {
            case .agent(_, let send): try await send(AgentClient(transport: transport))
            case .owner(_, let send): try await send(OwnerClient(transport: transport))
            }
        }
    }

    // The Questions and approvals operations.
    static let calls: [Call] = [
        .agent("ask_question") {
            _ = try await $0.askQuestion(taskID: taskID, AskQuestionRequest(text: "example", assumption: "example", blocking: false),
                key: key)
        },
        .agent("get_question") { _ = try await $0.getQuestion(taskID: taskID, questionID: relatedID) },
        .agent("request_access") {
            _ = try await $0.requestAccess(taskID: taskID, RequestAccessRequest(description: "example"),
                key: key)
        },
        .agent("report_cost") {
            _ = try await $0.reportCost(taskID: taskID, ReportCostRequest(tokens: 1, spend: 0),
                key: key)
        },
        .agent("start_action") { _ = try await $0.startAction(taskID: taskID, actionID: relatedID, key: key) },
        .agent("report_action_done") {
            _ = try await $0.reportActionDone(taskID: taskID, actionID: relatedID,
                key: key)
        },
        .owner("list_decisions") { _ = try await $0.listDecisions() },
        .owner("list_projects") { _ = try await $0.listProjects() },
        .owner("create_project") {
            _ = try await $0.createProject(CreateProjectRequest(name: "example"),
                key: key)
        },
        .owner("edit_brief") {
            _ = try await $0.editBrief(projectID: taskID, EditBriefRequest(entries: [BriefEntryInput(kind: .rule, text: "example")]),
                key: key)
        },
        .owner("pause_project") { _ = try await $0.pauseProject(projectID: taskID, key: key) },
        .owner("resume_project") { _ = try await $0.resumeProject(projectID: taskID, key: key) },
        .owner("delete_project_content") { _ = try await $0.deleteProjectContent(projectID: taskID, key: key) },
        .owner("change_budget") {
            _ = try await $0.changeBudget(projectID: taskID, ChangeBudgetRequest(budget: 0),
                key: key)
        },
        .owner("change_task_priority") {
            _ = try await $0.changeTaskPriority(taskID: taskID, ChangeTaskPriorityRequest(priority: .low),
                key: key)
        },
        .owner("change_task_project") {
            _ = try await $0.changeTaskProject(taskID: taskID, ChangeTaskProjectRequest(projectID: UUID(uuidString: "00000000-0000-4000-8000-000000000128")),
                key: key)
        },
        .owner("change_task_cap") {
            _ = try await $0.changeTaskCap(taskID: taskID, ChangeTaskCapRequest(budgetCap: 0),
                key: key)
        },
        .owner("return_for_rework") {
            _ = try await $0.returnForRework(taskID: taskID, ReturnForReworkRequest(criterionIDs: [UUID(uuidString: "00000000-0000-4000-8000-000000000001")!]),
                key: key)
        },
        .owner("offer_task_again") { _ = try await $0.offerTaskAgain(taskID: taskID, key: key) },
        .owner("grant_access") { _ = try await $0.grantAccess(taskID: taskID, key: key) },
        .owner("delete_task_content") { _ = try await $0.deleteTaskContent(taskID: taskID, key: key) },
        .owner("answer_question") {
            _ = try await $0.answerQuestion(questionID: taskID, AnswerQuestionRequest(answer: "example"),
                key: key)
        },
        .owner("overturn_answer") { _ = try await $0.overturnAnswer(questionID: taskID, key: key) },
        .owner("approve_action") { _ = try await $0.approveAction(actionID: taskID, key: key) },
        .owner("stop_action") { _ = try await $0.stopAction(actionID: taskID, key: key) },
        .owner("waive_action") { _ = try await $0.waiveAction(actionID: taskID, key: key) },
        .owner("mark_action_done") { _ = try await $0.markActionDone(actionID: taskID, key: key) },
        .owner("overturn_approval") { _ = try await $0.overturnApproval(actionID: taskID, key: key) },
        .owner("change_workspace_settings") {
            _ = try await $0.changeWorkspaceSettings(ChangeWorkspaceSettingsRequest(),
                key: key)
        },
        .owner("get_workspace_settings") { _ = try await $0.workspaceSettings() },
    ]

    @Test("Each client sends its operation's method, path, key and JSON", arguments: calls)
    func sendsContractRequest(_ call: Call) async throws {
        let contract = try #require(ContractDocument.openAPIOperation(call.operation))
        let entry = try #require(ContractDocument.operation(call.operation))
        let method = try #require(entry["method"]?.stringValue)
        let template = try #require(entry["path"]?.stringValue)
        let response = try #require(ContractDocument.responses(of: call.operation).first { $0.status == "200" })
        let example = try #require(ContractDocument.examples(of: response.component).first)
        let host = "\(call.operation.replacingOccurrences(of: "_", with: "-")).m5.test"
        let session = StubURLProtocol.session(
            host: host, answer: .init(status: 200, body: try ContractDocument.data(example)))
        defer { session.invalidateAndCancel() }
        let transport = HTTPTransport(baseURL: URL(string: "http://\(host)")!, token: Self.bearer, session: session)

        try await call.send(through: transport)

        let requests = StubURLProtocol.requests(host: host)
        #expect(requests.count == 1)
        let sent = try #require(requests.first)
        #expect(sent.method == method)
        #expect(sent.url?.path == expectedPath(template))
        #expect(sent.header("Authorization") == "Bearer \(Self.bearer)")
        #expect(sent.header("Idempotency-Key") == (method == "POST" ? Self.key.value : nil))
        #expect(sent.url?.query == nil)

        if let ref = contract["requestBody"]?["content"]?["application/json"]?["schema"]?["$ref"]?.stringValue {
            let component = try #require(ContractDocument.component(of: ref))
            let expected = try #require(ContractDocument.examples(of: component).first)
            let body = try #require(sent.body)
            #expect(sent.header("Content-Type") == "application/json")
            let matchesContract = try JSONDecoder().decode(JSONValue.self, from: body) == expected
            #expect(matchesContract)
        } else {
            #expect(sent.body == nil || sent.body?.isEmpty == true)
        }
    }

    private func expectedPath(_ template: String) -> String {
        let id = Self.taskID.uuidString.lowercased()
        let related = Self.relatedID.uuidString.lowercased()
        return template.replacingOccurrences(of: "{id}", with: id)
            .replacingOccurrences(of: "{qid}", with: related)
            .replacingOccurrences(of: "{aid}", with: related)
    }
}
