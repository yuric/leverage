import Foundation
import LeverageTestSupport
import Testing
@testable import LeverageKit

@Suite("HTTPTransport")
struct HTTPTransportTests {
    /// A made-up token: the prefix is a seat token's, the rest is not random.
    static let token = "lvs_made-up-token-for-transport-tests"

    private func transport(
        _ host: String, answers: [StubURLProtocol.Answer], token: String? = Self.token
    ) -> HTTPTransport {
        HTTPTransport(
            baseURL: URL(string: "http://\(host):3000")!, token: token,
            session: StubURLProtocol.session(host: host, answers: answers),
            retry: RetryPolicy(attempts: 3, pause: .zero))
    }

    private static let completedHeartbeat = StubURLProtocol.Answer(status: 200, json: """
        {"key":"k-1","command":"heartbeat","outcome":"completed",
         "result":{"lease_due_at":"2026-01-01T01:00:00Z"},"refusal":null}
        """)

    @Test("a command sends its key, the bearer token and JSON")
    func commandHeaders() async throws {
        let transport = transport("headers.test", answers: [Self.completedHeartbeat])
        let key = IdempotencyKey()

        _ = try await transport.command(
            .acknowledgeTaskBriefing, JSONValue.self, path: ["id": "00000000-0000-4000-8000-000000000001"],
            body: AcknowledgeBriefingRequest(briefingHash: "made-up-hash"), key: key)

        let request = try #require(StubURLProtocol.requests(host: "headers.test").last)
        #expect(request.method == "POST")
        #expect(request.header("Idempotency-Key") == key.value)
        #expect(request.header("Authorization") == "Bearer \(Self.token)")
        #expect(request.header("Content-Type") == "application/json")
        #expect(request.header("Accept") == "application/json")
        let body = try #require(request.body)
        #expect(try JSONDecoder().decode(JSONValue.self, from: body) == .object(["briefing_hash": .string("made-up-hash")]))
        #expect(request.url?.path == "/v1/tasks/00000000-0000-4000-8000-000000000001/ack-briefing")
    }

    @Test("a read sends no key; a public call and a missing token send no bearer")
    func readHeaders() async throws {
        let transport = transport(
            "read.test", answers: [.init(status: 200, json: #"{"owner_exists":false}"#)])

        let state: SetupState = try await transport.read(.getSetupState, signedIn: false)
        #expect(state == SetupState(ownerExists: false))
        let request = try #require(StubURLProtocol.requests(host: "read.test").last)
        #expect(request.method == "GET")
        #expect(request.header("Idempotency-Key") == nil)
        #expect(request.header("Authorization") == nil)

        let anonymous = self.transport(
            "anonymous.test", answers: [.init(status: 200, json: #"{"owner_exists":true}"#)], token: nil)
        let _: SetupState = try await anonymous.read(.getSetupState)
        #expect(StubURLProtocol.requests(host: "anonymous.test").last?.header("Authorization") == nil)
    }

    @Test("a retry after a lost connection sends the same key")
    func retrySameKey() async throws {
        let transport = transport(
            "retry.test", answers: [.failure(.networkConnectionLost), .failure(.timedOut), Self.completedHeartbeat])
        let key = IdempotencyKey()

        let outcome = try await transport.command(
            .heartbeatTask, HeartbeatResult.self, path: ["id": "00000000-0000-4000-8000-000000000001"],
            key: key)

        #expect(outcome.outcome == .completed)
        let requests = StubURLProtocol.requests(host: "retry.test")
        #expect(requests.count == 3)
        #expect(requests.allSatisfy { $0.header("Idempotency-Key") == key.value })
    }

    @Test("a command gives up after the policy's attempts with the network's error")
    func retryGivesUp() async throws {
        let transport = transport("giveup.test", answers: [.failure(.cannotConnectToHost)])

        await #expect(throws: URLError.self) {
            _ = try await transport.command(.signOutOwner, JSONValue.self, key: IdempotencyKey())
        }
        #expect(StubURLProtocol.requests(host: "giveup.test").count == 3)
    }

    @Test("a read is not retried: its caller asks again")
    func readNotRetried() async throws {
        let transport = transport("readonce.test", answers: [.failure(.networkConnectionLost)])

        await #expect(throws: URLError.self) {
            let _: Board = try await transport.read(.getBoard)
        }
        #expect(StubURLProtocol.requests(host: "readonce.test").count == 1)
    }

    @Test("200 is a completed outcome with its result")
    func completed() async throws {
        let transport = transport("ok.test", answers: [Self.completedHeartbeat])
        let outcome = try await transport.command(
            .heartbeatTask, HeartbeatResult.self, path: ["id": "00000000-0000-4000-8000-000000000001"],
            key: IdempotencyKey())
        #expect(outcome.outcome == .completed)
        #expect(outcome.command == .heartbeat)
        #expect(outcome.result?.leaseDueAt == LeverageJSON.date(from: "2026-01-01T01:00:00Z"))
        #expect(try outcome.completedResult()?.leaseDueAt == outcome.result?.leaseDueAt)
    }

    @Test("202 is a pending outcome")
    func pending() async throws {
        let transport = transport("pending.test", answers: [.init(status: 202, json: """
            {"key":"k-2","command":"submit","outcome":"pending","result":null,"refusal":null}
            """)])
        let outcome = try await transport.command(
            .submitTask, JSONValue.self, path: ["id": "00000000-0000-4000-8000-000000000001"],
            body: SubmitTaskRequest(handoffNote: "made-up note", workReference: nil),
            key: IdempotencyKey())
        #expect(outcome.outcome == .pending)
        #expect(outcome.result == nil)
        #expect(throws: LeverageClientError.pending(.submit)) { try outcome.completedResult() }
    }

    @Test("409 is a refused outcome with its refusal")
    func refused() async throws {
        let transport = transport("refused.test", answers: [.init(status: 409, json: """
            {"key":"k-3","command":"submit","outcome":"refused","result":null,
             "refusal":{"code":"criteria_incomplete","rule_id":null,"reason":null}}
            """)])
        let outcome = try await transport.command(
            .submitTask, JSONValue.self, path: ["id": "00000000-0000-4000-8000-000000000001"],
            key: IdempotencyKey())
        #expect(outcome.outcome == .refused)
        let refusal = Refusal(code: .criteriaIncomplete, ruleID: nil, reason: nil)
        #expect(outcome.refusal == refusal)
        #expect(throws: LeverageClientError.refused(refusal)) { try outcome.completedResult() }
        #expect(StubURLProtocol.requests(host: "refused.test").count == 1)
    }

    @Test("a read answered 409 throws its refusal")
    func readRefused() async throws {
        let transport = transport("readrefused.test", answers: [.init(status: 409, json: """
            {"code":"invalid_state","rule_id":null,"reason":null}
            """)])
        await #expect(throws: LeverageClientError.refused(Refusal(code: .invalidState, ruleID: nil, reason: nil))) {
            let _: LandingPrompt = try await transport.read(
                .getLandingPrompt, path: ["id": "00000000-0000-4000-8000-000000000001"])
        }
    }

    @Test("each transport code is thrown with its status, and never retried",
          arguments: [(400, "malformed"), (401, "unauthenticated"), (404, "not_found"),
                      (422, "key_reused"), (422, "invalid")])
    func transportErrors(status: Int, code: String) async throws {
        let host = "transport-\(code.replacingOccurrences(of: "_", with: "-")).test"
        let transport = transport(host, answers: [.init(status: status, json: """
            {"error":{"code":"\(code)","message":"made-up message"}}
            """)])
        do {
            _ = try await transport.command(.addTask, TaskCreatedResult.self,
                                            body: AddTaskRequest(title: "t", goal: "g"), key: IdempotencyKey())
            Issue.record("no error thrown")
        } catch let error as TransportError {
            #expect(error.code.rawValue == code)
            #expect(error.status == status)
            #expect(error.message == "made-up message")
        }
        #expect(StubURLProtocol.requests(host: host).count == 1)

        do {
            let _: Board = try await transport.read(.getBoard)
            Issue.record("no error thrown on a read")
        } catch let error as TransportError {
            #expect(error.code.rawValue == code)
        }
    }

    @Test("a status the contract does not give, or a body that does not fit it, is not trusted")
    func unexpected() async throws {
        let server = transport("server.test", answers: [.init(status: 500, json: "{}")])
        await #expect(throws: LeverageClientError.unexpectedStatus(500)) {
            let _: Board = try await server.read(.getBoard)
        }

        let mismatch = transport("mismatch.test", answers: [.init(status: 200, json: """
            {"key":"k","command":"submit","outcome":"refused","result":null,
             "refusal":{"code":"on_hold","rule_id":null,"reason":null}}
            """)])
        await #expect(throws: LeverageClientError.invalidBody) {
            _ = try await mismatch.command(.submitTask, JSONValue.self,
                                           path: ["id": "00000000-0000-4000-8000-000000000001"], key: IdempotencyKey())
        }

        let garbled = transport("garbled.test", answers: [.init(status: 200, json: "not json")])
        await #expect(throws: LeverageClientError.invalidBody) {
            let _: Board = try await garbled.read(.getBoard)
        }

        let wrongCode = transport("wrongcode.test", answers: [.init(status: 400, json: """
            {"error":{"code":"unauthenticated","message":"m"}}
            """)])
        await #expect(throws: LeverageClientError.unexpectedStatus(400)) {
            let _: Board = try await wrongCode.read(.getBoard)
        }
    }

    @Test("a long poll waits longer than the server may hold it")
    func longPollTimeout() async throws {
        let transport = transport(
            "poll.test", answers: [.init(status: 200, json: #"{"kind":"none","id":null,"review_id":null}"#)])

        let item: NextItem = try await transport.read(.getNext, waitSeconds: 30)

        #expect(item.kind == .none)
        let request = try #require(StubURLProtocol.requests(host: "poll.test").last)
        #expect(request.url?.query == "wait=30")
        #expect(request.request.timeoutInterval >= 30 + HTTPTransport.longPollMargin)
        #expect(HTTPTransport.longPollMargin >= 10)
    }

    @Test("a path keeps the base URL's own path and fills every parameter")
    func paths() throws {
        let transport = HTTPTransport(baseURL: URL(string: "http://paths.test/leverage/")!)
        let url = try transport.url(
            for: .startCriterion,
            path: ["id": "00000000-0000-4000-8000-00000000000a", "cid": "00000000-0000-4000-8000-00000000000b"],
            query: [URLQueryItem(name: "wait", value: "5")])
        #expect(url.absoluteString
            == "http://paths.test/leverage/v1/tasks/00000000-0000-4000-8000-00000000000a/criteria/00000000-0000-4000-8000-00000000000b/start?wait=5")
        #expect(throws: LeverageClientError.missingPathParameter("cid")) {
            _ = try transport.url(for: .startCriterion, path: ["id": "x"])
        }
    }
}

@Suite("IdempotencyKey")
struct IdempotencyKeyTests {
    @Test("a new key per command, in the contract's key format")
    func newKeys() {
        let keys = (0..<50).map { _ in IdempotencyKey() }
        #expect(Set(keys).count == 50)
        for key in keys {
            #expect((1...128).contains(key.value.count))
            #expect(key.value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        }
    }

    @Test("a kept key is the same key: a retry sends it again")
    func keptKey() {
        let key = IdempotencyKey()
        #expect(IdempotencyKey(key.value) == key)
        #expect(IdempotencyKey("add-task_1") != nil)
    }

    @Test("a value outside the key format is not a key")
    func invalid() {
        #expect(IdempotencyKey("") == nil)
        #expect(IdempotencyKey("has space") == nil)
        #expect(IdempotencyKey("slash/key") == nil)
        #expect(IdempotencyKey(String(repeating: "a", count: 129)) == nil)
        #expect(IdempotencyKey(String(repeating: "a", count: 128)) != nil)
    }
}
