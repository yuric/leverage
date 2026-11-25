import Foundation
import LeverageTestSupport
import Testing
@testable import LeverageKit

@Suite("Agent model reports and task creation")
struct RoundTwoClientTests {
    private let key = IdempotencyKey("made-up-round-two-command")!

    @Test("Seat permissions decode and both owner commands encode the entire set")
    func permissions() throws {
        let data = Data("""
            {"id":"00000000-0000-4000-8000-000000000301","name":"Builder","provider":"claude",
             "role":"builder","enabled":true,"paused":false,"wanted_running":false,
             "permissions":{"work":false,"deliver":true,"create":false}}
            """.utf8)
        let seat = try LeverageJSON.decoder().decode(Seat.self, from: data)
        let permissions = SeatPermissions(work: false, deliver: true, create: false)
        #expect(seat.permissions == permissions)
        let expected: JSONValue = .object(["work": .bool(false), "deliver": .bool(true), "create": .bool(false)])
        #expect(FakeCall.json(ConnectSeatRequest(name: "Builder", role: .builder, permissions: permissions))?["permissions"] == expected)
        #expect(FakeCall.json(ChangeSeatRequest(permissions: permissions))?["permissions"] == expected)
        #expect(FakeCall.json(ChangeSeatRequest())?["permissions"] == nil)
    }

    @Test("Each login's settings are read from the generated model catalog")
    func catalog() throws {
        for provider in Provider.allCases where provider.kind == .login {
            let generated = try #require(ModelCatalog.entry(for: provider))
            let entry = try #require(ProviderCatalog.entry(for: provider.rawValue))
            #expect(entry.models == generated.models)
            #expect(entry.defaultModel == generated.defaultModel)
        }
    }

    @Test("A model report posts both nullable keys and decodes the stored values")
    func reportModel() async throws {
        let host = "report-model.round-two.test"
        let session = StubURLProtocol.session(host: host, answer: .init(status: 200, body: Data("""
            {"key":"made-up-round-two-command","command":"change_seat","outcome":"completed",
             "result":{"model":"","effort":""},"refusal":null}
            """.utf8)))
        defer { session.invalidateAndCancel() }
        let api: any AgentAPI = AgentClient(baseURL: URL(string: "http://\(host)")!, seatToken: "made-up", session: session)
        let result = try await api.reportModel(ReportModelRequest(model: nil, effort: nil), key: key).completedResult()
        #expect(result?.model == "" && result?.effort == "")
        let sent = try #require(StubURLProtocol.requests(host: host).first)
        #expect(sent.method == "POST")
        #expect(sent.url?.path == "/v1/seat/model")
        #expect(sent.header("Idempotency-Key") == key.value)
        let body = try LeverageJSON.decoder().decode([String: JSONValue].self, from: #require(sent.body))
        #expect(body == ["model": .null, "effort": .null])
    }

    @Test("An agent posts only its Add task fields and reads where the task stands")
    func createTask() async throws {
        let host = "create-task.round-two.test"
        let session = StubURLProtocol.session(host: host, answer: .init(status: 200, body: Data("""
            {"key":"made-up-round-two-command","command":"add_task","outcome":"completed",
             "result":{"task_id":"00000000-0000-4000-8000-000000000301","state":"backlog"},"refusal":null}
            """.utf8)))
        defer { session.invalidateAndCancel() }
        let api: any AgentAPI = AgentClient(baseURL: URL(string: "http://\(host)")!, seatToken: "made-up", session: session)
        let request = CreateTaskRequest(title: "Check invoices", details: "Use the sample invoices",
                                        criteria: [CriterionInput(text: "Review totals", kind: .review)])
        let result = try await api.createTask(request, key: key).completedResult()
        #expect(result?.taskID == UUID(uuidString: "00000000-0000-4000-8000-000000000301"))
        #expect(result?.state == .backlog)
        let sent = try #require(StubURLProtocol.requests(host: host).first)
        #expect(sent.method == "POST")
        #expect(sent.url?.path == "/v1/tasks")
        #expect(sent.header("Idempotency-Key") == key.value)
        let body = try LeverageJSON.decoder().decode([String: JSONValue].self, from: #require(sent.body))
        #expect(body == ["title": .string("Check invoices"), "details": .string("Use the sample invoices"),
                         "criteria": .array([.object(["text": .string("Review totals"), "kind": .string("review")])])])
    }
}
