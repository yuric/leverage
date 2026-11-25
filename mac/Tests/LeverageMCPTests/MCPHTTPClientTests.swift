import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LeverageKit
import LeverageTestSupport
import Testing
@testable import LeverageMCP

struct MCPHTTPClientTests {
    @Test func getJoinRequestsMCPInstructions() async throws {
        let host = "mcp-join-fixture.invalid"
        let session = StubURLProtocol.session(host: host, answer: .init(status: 200, json: """
            {"text":"Fixture instructions","role":"general","connection":"mcp",
             "permissions":{"work":true,"deliver":false,"create":true},
             "models":[{"id":"claude-opus-5-5","efforts":["high"]}],"unused":"fixture metadata"}
            """))
        defer { session.invalidateAndCancel() }
        let transport = HTTPTransport(
            baseURL: URL(string: "http://\(host)")!, token: "fixture-not-a-seat-token", session: session)

        let answer = try await MCPHTTPClient(transport: transport).send(ToolRequest(operation: .getJoin))

        #expect(answer.status == 200)
        #expect(answer.body == .object([
            "text": .string("Fixture instructions"), "role": .string("general"), "connection": .string("mcp"),
            "permissions": .object(["work": .bool(true), "deliver": .bool(false), "create": .bool(true)]),
            "models": .array([.object(["id": .string("claude-opus-5-5"), "efforts": .array([.string("high")])])]),
        ]))
        let requests = StubURLProtocol.requests(host: host)
        try #require(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.method == "GET")
        #expect(request.url?.path == "/v1/join")
        #expect(request.url?.query == "connection=mcp")
        let hasAuthorization = request.header("Authorization") == "Bearer fixture-not-a-seat-token"
        #expect(hasAuthorization)
        #expect(request.body == nil)
    }

    @Test func sendsPathBodyAndHeadersAndRetriesWithIdenticalKeyAndBytes() async throws {
        let host = "mcp-retry-fixture.invalid"
        let session = StubURLProtocol.session(host: host, answers: [
            .failure(.networkConnectionLost),
            .failure(.timedOut),
            .init(status: 200, json: """
                {"key":"fixture-fixed-key","command":"ask_question","outcome":"completed","result":null,"refusal":null}
                """)
        ])
        defer { session.invalidateAndCancel() }
        let transport = HTTPTransport(
            baseURL: URL(string: "http://\(host)")!, token: "fixture-not-a-seat-token",
            session: session, retry: RetryPolicy(attempts: 3, pause: .zero))
        let key = try #require(IdempotencyKey("fixture-fixed-key"))
        let body: [String: JSONValue] = ["text": .string("fixture text"),
                                        "assumption": .string("fixture assumption"), "blocking": .bool(false)]
        let answer = try await MCPHTTPClient(transport: transport).send(ToolRequest(
            operation: .askQuestion, path: ["id": taskID], body: body, key: key))
        #expect(answer.status == 200)
        #expect(answer.body["outcome"] == .string("completed"))
        let requests = StubURLProtocol.requests(host: host)
        try #require(requests.count == 3)
        for request in requests {
            #expect(request.method == "POST")
            #expect(request.url?.path == "/v1/tasks/\(taskID)/questions")
            #expect(request.header("Content-Type") == "application/json")
            #expect(request.header("Idempotency-Key") == key.value)
            let hasAuthorization = request.header("Authorization") == "Bearer fixture-not-a-seat-token"
            #expect(hasAuthorization)
            let bytes = try #require(request.body)
            let retriesIdenticalBytes = bytes == requests.first?.body
            #expect(retriesIdenticalBytes)
            let forwardsBody = try LeverageJSON.decoder().decode(JSONValue.self, from: bytes) == .object(body)
            #expect(forwardsBody)
        }
    }
}
