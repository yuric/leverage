import Foundation
import LeverageKit
@testable import LeverageMCP
import LeverageTestSupport
import Testing

@Suite(.serialized, .timeLimit(.minutes(Patience.minutes(1))))
struct ScriptedSessionTests {
    @Test(arguments: [
        "2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05", "2099-01-01",
    ])
    func negotiatesProtocolRevision(_ revision: String) async throws {
        try await withSession { client in
            let response = try client.initialize(protocolVersion: revision)
            #expect(response["jsonrpc"] as? String == "2.0")
            let result = try #require(response["result"] as? [String: Any])
            #expect(result["protocolVersion"] as? String == (revision == "2099-01-01" ? "2025-06-18" : revision))
            let capabilities = try #require(result["capabilities"] as? [String: Any])
            #expect(Set(capabilities.keys) == ["tools"])
            let server = try #require(result["serverInfo"] as? [String: Any])
            #expect(server["name"] as? String == "leverage")
        }
    }

    @Test func listsAndCallsToolsAfterInitialization() async throws {
        let api = ScriptedSessionAPI()
        try await withSession(transport: api.reply) { client in
            _ = try client.initialize(protocolVersion: "2025-06-18")
            try client.send(request("tools/list", id: 20))
            let response = try #require(try client.receive() as? [String: Any])
            #expect(response["id"] as? Int == 20)
            let result = try #require(response["result"] as? [String: Any])
            let tools = try #require(result["tools"] as? [[String: Any]])
            #expect(tools.count == 25)
            let next = try #require(tools.first { $0["name"] as? String == "get_next" })
            let schema = try #require(next["inputSchema"] as? [String: Any])
            #expect(schema["type"] as? String == "object")

            let reply = try client.call(name: "get_next", arguments: ["wait": 0])
            #expect(reply["isError"] as? Bool != true)
            let content = try #require(reply["content"] as? [[String: Any]])
            #expect(content.count == 1)
            let item = try #require(content.first)
            #expect(item["type"] as? String == "text")
            let text = try #require(item["text"] as? String)
            let payload = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            #expect(payload["status"] as? Int == 200)
            #expect(payload["body"] as? [String: String] == ["kind": "none"])
        }
        let requests = await api.requests
        #expect(requests.map(\.operation) == [.getNext])
        #expect(requests.map(\.wait) == [0])
    }

    @Test func mixedBatchRepliesOnlyToRequests() async throws {
        try await withSession { client in
            _ = try client.initialize(protocolVersion: "2025-06-18")
            try client.send([
                request("ping", id: 21),
                ["jsonrpc": "2.0", "method": "notifications/unrecognized"],
                request("unknown", id: 22),
            ])
            let batch = try #require(try client.receive() as? [[String: Any]])
            #expect(batch.count == 2)
            let pong = try #require(batch.first { $0["id"] as? Int == 21 })
            let result = try #require(pong["result"] as? [String: Any])
            #expect(result.isEmpty)
            let unknown = try #require(batch.first { $0["id"] as? Int == 22 })
            let error = try #require(unknown["error"] as? [String: Any])
            #expect(error["code"] as? Int == -32601)
        }
    }

    @Test func pipelinedCallsRunSeriallyAndReplyInOrder() async throws {
        let api = ScriptedSessionAPI(firstCallDelay: Patience.scaled(.milliseconds(100)))
        try await withSession(transport: api.reply) { client in
            _ = try client.initialize(protocolVersion: "2025-06-18")
            try client.send(request("tools/call", id: 30, params: ["name": "get_next", "arguments": ["wait": 1]]))
            try client.send(request("tools/call", id: 31, params: ["name": "get_next", "arguments": ["wait": 2]]))
            let first = try #require(try client.receive() as? [String: Any])
            let second = try #require(try client.receive() as? [String: Any])
            #expect(first["id"] as? Int == 30)
            #expect(second["id"] as? Int == 31)
            #expect(first["result"] is [String: Any])
            #expect(second["result"] is [String: Any])
        }
        let requests = await api.requests
        #expect(requests.map(\.wait) == [1, 2])
        #expect(await api.peakInFlight == 1)
    }

    @Test func malformedLineReturnsParseErrorAndKeepsSessionAlive() async throws {
        try await withSession { client in
            _ = try client.initialize(protocolVersion: "2025-06-18")
            try client.sendLine("{")
            try client.send(request("ping", id: 40))
            let malformed = try #require(try client.receive() as? [String: Any])
            #expect(malformed["jsonrpc"] as? String == "2.0")
            #expect(malformed["id"] is NSNull)
            let error = try #require(malformed["error"] as? [String: Any])
            #expect(error["code"] as? Int == -32700)
            let pong = try #require(try client.receive() as? [String: Any])
            #expect(pong["id"] as? Int == 40)
            #expect(pong["result"] is [String: Any])
        }
    }

    @Test func rejectsScalarParamsWithTheRequestID() async throws {
        try await withSession { client in
            _ = try client.initialize()
            try client.send(["jsonrpc": "2.0", "id": 41, "method": "ping", "params": 7])
            let reply = try #require(try client.receive() as? [String: Any])
            #expect(reply["id"] as? Int == 41)
            #expect((reply["error"] as? [String: Any])?["code"] as? Int == -32602)
        }
    }

    @Test func apiResponseCannotEchoTheConfiguredSeatToken() async throws {
        let token = "fixture-secret-\(UUID().uuidString)"
        try await withSession(transport: { _ in
            ToolResponse(status: 200, body: .object([
                "records": .array([.object(["label": .string("prefix-\(token)-suffix")])]),
                token: .bool(true), "kind": .string("none")
            ]))
        }, token: token) { client in
            _ = try client.initialize()
            let reply = try client.call(name: "get_next", arguments: ["wait": 0])
            let content = try #require(reply["content"] as? [[String: Any]])
            let text = try #require(content.first?["text"] as? String)
            let containsToken = text.contains(token)
            #expect(!containsToken)
            let body = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            let preservedOtherFields = (body["body"] as? [String: Any])?["kind"] as? String == "none"
            #expect(preservedOtherFields)
        }
    }

    @Test func pingInitializationAndListingDoNotRenewActivity() async throws {
        let clock = ManualMCPClock()
        let api = RecordingTransport([claim(taskID)])
        let caller = ToolCaller(transport: api.send, now: clock.now)
        try await withSession(caller: caller) { client in
            _ = try client.initialize()
            _ = try client.call(name: "claim_next_task")
            clock.advance(by: .seconds(600))
            try client.send(request("ping", id: 50))
            _ = try #require(try client.receive() as? [String: Any])
            _ = try client.initialize()
            try client.send(request("tools/list", id: 51))
            _ = try #require(try client.receive() as? [String: Any])
        }
        await caller.heartbeat()
        #expect(await api.requests.map(\.operation) == [.claimNextTask])
    }

    private func request(_ method: String, id: Int, params: [String: Any] = [:]) -> [String: Any] {
        ["jsonrpc": "2.0", "method": method, "id": id, "params": params]
    }

    private func withSession(
        transport: @escaping @Sendable (ToolRequest) async throws -> ToolResponse = { _ in
            Issue.record("Unexpected HTTP request")
            return ToolResponse(status: 500, body: .null)
        },
        caller: ToolCaller? = nil,
        token: String = "fixture-seat-value",
        _ check: (ScriptedMCPClient) throws -> Void
    ) async throws {
        let input = Pipe()
        let output = Pipe()
        let client = ScriptedMCPClient(input: input.fileHandleForWriting, output: output.fileHandleForReading)
        let task = Task.detached {
            // Closing the writer also lets the client observe EOF if the server fails.
            defer { try? output.fileHandleForWriting.close() }
            let server = MCPServer(
                input: input.fileHandleForReading,
                output: output.fileHandleForWriting,
                caller: caller ?? ToolCaller(transport: transport),
                catalog: ToolCatalog(),
                log: Log(component: "mcp", write: { _ in }),
                token: token
            )
            try await server.run()
        }
        do {
            try check(client)
        } catch {
            try? client.closeInput()
            _ = try? await task.value
            throw error
        }
        try client.closeInput()
        try await task.value
        #expect(try client.receive() == nil)
    }
}

private actor ScriptedSessionAPI {
    private let firstCallDelay: Duration?
    private var inFlight = 0
    private(set) var peakInFlight = 0
    private(set) var requests: [ToolRequest] = []

    init(firstCallDelay: Duration? = nil) {
        self.firstCallDelay = firstCallDelay
    }

    func reply(to request: ToolRequest) async throws -> ToolResponse {
        requests.append(request)
        inFlight += 1
        peakInFlight = max(peakInFlight, inFlight)
        defer { inFlight -= 1 }
        if requests.count == 1, let firstCallDelay {
            try await Task.sleep(for: firstCallDelay)
        }
        return ToolResponse(status: 200, body: .object(["kind": .string("none")]))
    }
}
