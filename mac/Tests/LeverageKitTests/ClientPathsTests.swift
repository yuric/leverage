import Foundation
import LeverageTestSupport
import Testing
@testable import LeverageKit

// Each client method is called against a stub that answers with the
// contract's own example, and the request it sent is compared with the
// registry (IN-1): the method, the path, the query, the key header, the
// bearer token, and the body against the operation's request schema.

private enum Fixture {
    static let ownerToken = "lvo_made-up-owner-session-for-tests"
    static let seatToken = "lvs_made-up-seat-token-for-tests"
    static let helperToken = "lvh_made-up-helper-token-for-tests"

    static let task = UUID(uuidString: "00000000-0000-4000-8000-0000000000A1")!
    static let criterion = UUID(uuidString: "00000000-0000-4000-8000-0000000000A2")!
    static let review = UUID(uuidString: "00000000-0000-4000-8000-0000000000A3")!
    static let seat = UUID(uuidString: "00000000-0000-4000-8000-0000000000A4")!
    static let credential = UUID(uuidString: "00000000-0000-4000-8000-0000000000A5")!
    static let request = UUID(uuidString: "00000000-0000-4000-8000-0000000000A6")!
    static let observed = Date(timeIntervalSince1970: 1_767_225_600.5)

    static func id(_ uuid: UUID) -> String { uuid.uuidString.lowercased() }
    static func key(_ operation: String) -> IdempotencyKey { IdempotencyKey("key-\(operation)")! }

    static let signIn = SignInRequest(emailAddress: "owner@example.invalid", password: "made-up-password")
}

/// The four clients, each with its own made-up token, all on one host.
struct Clients: Sendable {
    let owner: OwnerClient
    let agent: AgentClient
    let helper: HelperClient
    let infrastructure: LeverageClient

    init(baseURL: URL, session: URLSession) {
        owner = OwnerClient(baseURL: baseURL, sessionToken: Fixture.ownerToken, session: session)
        agent = AgentClient(baseURL: baseURL, seatToken: Fixture.seatToken, session: session)
        helper = HelperClient(baseURL: baseURL, helperToken: Fixture.helperToken, session: session)
        infrastructure = LeverageClient(baseURL: baseURL, session: session)
    }
}

struct ClientCall: Sendable {
    var path: [String: String] = [:]
    var query: [String: String] = [:]
    let call: @Sendable (Clients) async throws -> Void
}

@Suite("Client paths")
struct ClientPathsTests {
    private typealias F = Fixture

    static let calls: [String: ClientCall] = [
        // Agent
        "get_next": ClientCall(query: ["wait": "30"]) { _ = try await $0.agent.next(wait: 30) },
        "get_command": ClientCall(path: ["key": "key-get_command"]) {
            _ = try await $0.agent.command(key: F.key("get_command"))
        },
        "claim_next_task": ClientCall { _ = try await $0.agent.claimNextTask(key: F.key("claim_next_task")) },
        "get_task_briefing": ClientCall(path: ["id": F.id(F.task)]) {
            _ = try await $0.agent.taskBriefing(taskID: F.task)
        },
        "acknowledge_task_briefing": ClientCall(path: ["id": F.id(F.task)]) {
            _ = try await $0.agent.acknowledgeTaskBriefing(
                taskID: F.task, briefingHash: "made-up-hash", key: F.key("acknowledge_task_briefing"))
        },
        "heartbeat_task": ClientCall(path: ["id": F.id(F.task)]) {
            _ = try await $0.agent.heartbeatTask(taskID: F.task, key: F.key("heartbeat_task"))
        },
        "start_criterion": ClientCall(path: ["id": F.id(F.task), "cid": F.id(F.criterion)]) {
            _ = try await $0.agent.startCriterion(
                taskID: F.task, criterionID: F.criterion, key: F.key("start_criterion"))
        },
        "pass_criterion": ClientCall(path: ["id": F.id(F.task), "cid": F.id(F.criterion)]) {
            _ = try await $0.agent.passCriterion(
                taskID: F.task, criterionID: F.criterion,
                evidence: EvidenceInput(kind: .note, value: "made-up note"), key: F.key("pass_criterion"))
        },
        "submit_task": ClientCall(path: ["id": F.id(F.task)]) {
            _ = try await $0.agent.submitTask(
                taskID: F.task, SubmitTaskRequest(handoffNote: "made-up note", workReference: nil),
                key: F.key("submit_task"))
        },
        "release_task": ClientCall(path: ["id": F.id(F.task)]) {
            _ = try await $0.agent.releaseTask(
                taskID: F.task, reason: .unableToContinue, key: F.key("release_task"))
        },
        "claim_next_review": ClientCall {
            _ = try await $0.agent.claimNextReview(key: F.key("claim_next_review"))
        },
        "heartbeat_review": ClientCall(path: ["id": F.id(F.review)]) {
            _ = try await $0.agent.heartbeatReview(reviewID: F.review, key: F.key("heartbeat_review"))
        },
        "release_review": ClientCall(path: ["id": F.id(F.review)]) {
            _ = try await $0.agent.releaseReview(reviewID: F.review, key: F.key("release_review"))
        },
        "get_review_briefing": ClientCall(path: ["id": F.id(F.review)]) {
            _ = try await $0.agent.reviewBriefing(reviewID: F.review)
        },
        "acknowledge_review_briefing": ClientCall(path: ["id": F.id(F.review)]) {
            _ = try await $0.agent.acknowledgeReviewBriefing(
                reviewID: F.review, briefingHash: "made-up-hash", key: F.key("acknowledge_review_briefing"))
        },
        "give_verdict": ClientCall(path: ["id": F.id(F.review)]) {
            _ = try await $0.agent.giveVerdict(
                reviewID: F.review,
                GiveVerdictRequest(
                    verdict: .failed, failedCriteria: [F.criterion], notes: "made-up notes", tokens: 0, spend: 0),
                key: F.key("give_verdict"))
        },
        // Infrastructure
        "get_health": ClientCall { _ = try await $0.infrastructure.health() },
        // Owner
        "get_setup_state": ClientCall { _ = try await $0.owner.setupState() },
        "create_owner": ClientCall {
            _ = try await $0.owner.createOwner(F.signIn, key: F.key("create_owner"))
        },
        "sign_in_owner": ClientCall { _ = try await $0.owner.signIn(F.signIn, key: F.key("sign_in_owner")) },
        "sign_out_owner": ClientCall { _ = try await $0.owner.signOut(key: F.key("sign_out_owner")) },
        "get_owner_command": ClientCall(path: ["key": "key-get_owner_command"]) {
            _ = try await $0.owner.command(key: F.key("get_owner_command"))
        },
        "list_events": ClientCall(query: ["after_seq": "12", "limit": "50", "wait": "30"]) {
            _ = try await $0.owner.events(afterSeq: 12, limit: 50, wait: 30)
        },
        "get_board": ClientCall { _ = try await $0.owner.board() },
        "get_task": ClientCall(path: ["id": F.id(F.task)]) { _ = try await $0.owner.task(id: F.task) },
        "list_seats": ClientCall { _ = try await $0.owner.seats() },
        "list_credentials": ClientCall { _ = try await $0.owner.credentials() },
        "get_system_health": ClientCall { _ = try await $0.owner.systemHealth() },
        "get_helper_request": ClientCall(
            path: ["id": F.id(F.request)], query: ["wait": "20", "changed_after": "2026-01-01T00:00:00.5Z"]
        ) {
            _ = try await $0.owner.helperRequest(id: F.request, wait: 20, changedAfter: F.observed)
        },
        "get_landing_prompt": ClientCall(path: ["id": F.id(F.seat)]) {
            _ = try await $0.owner.landingPrompt(seatID: F.seat)
        },
        "add_task": ClientCall {
            _ = try await $0.owner.addTask(
                AddTaskRequest(
                    title: "Made-up task", goal: "A made-up goal", priority: .normal, workReference: nil,
                    state: .backlog),
                key: F.key("add_task"))
        },
        "complete_contract": ClientCall(path: ["id": F.id(F.task)]) {
            _ = try await $0.owner.completeContract(
                taskID: F.task,
                CompleteContractRequest(
                    title: "Made-up task", goal: "A made-up goal", details: nil,
                    criteria: [CriterionInput(text: "It works", kind: .build)], actions: [],
                    minimumStrengthRank: nil, budgetCap: nil, workReference: nil),
                key: F.key("complete_contract"))
        },
        "cancel_task": ClientCall(path: ["id": F.id(F.task)]) {
            _ = try await $0.owner.cancelTask(taskID: F.task, key: F.key("cancel_task"))
        },
        "allow_another_round": ClientCall(path: ["id": F.id(F.task)]) {
            _ = try await $0.owner.allowAnotherRound(taskID: F.task, key: F.key("allow_another_round"))
        },
        "connect_seat": ClientCall {
            _ = try await $0.owner.connectSeat(
                ConnectSeatRequest(
                    name: "Made-up builder", role: .builder, provider: .claude, model: nil, effort: nil,
                    strengthRank: nil, credentialID: F.credential),
                key: F.key("connect_seat"))
        },
        "start_seat": ClientCall(path: ["id": F.id(F.seat)]) {
            _ = try await $0.owner.startSeat(seatID: F.seat, key: F.key("start_seat"))
        },
        "stop_seat": ClientCall(path: ["id": F.id(F.seat)]) {
            _ = try await $0.owner.stopSeat(seatID: F.seat, key: F.key("stop_seat"))
        },
        "remove_seat": ClientCall(path: ["id": F.id(F.seat)]) {
            _ = try await $0.owner.removeSeat(seatID: F.seat, key: F.key("remove_seat"))
        },
        "issue_helper_token": ClientCall {
            _ = try await $0.owner.issueHelperToken(name: "This Mac", key: F.key("issue_helper_token"))
        },
        "add_credential": ClientCall {
            _ = try await $0.owner.addCredential(
                AddCredentialRequest(
                    credentialID: F.credential, kind: .login, provider: .claude, name: "Made-up login",
                    maskedLabel: nil, model: nil, effort: nil, strengthRank: nil),
                key: F.key("add_credential"))
        },
        "verify_credential": ClientCall(path: ["id": F.id(F.credential)]) {
            _ = try await $0.owner.verifyCredential(credentialID: F.credential, key: F.key("verify_credential"))
        },
        "install_tool": ClientCall(path: ["provider": "codex"]) {
            _ = try await $0.owner.installTool(provider: .codex, key: F.key("install_tool"))
        },
        // Helper
        "get_helper_next": ClientCall(query: ["wait": "30"]) { _ = try await $0.helper.next(wait: 30) },
        "report_request_progress": ClientCall(path: ["id": F.id(F.request)]) {
            _ = try await $0.helper.reportRequestProgress(
                requestID: F.request,
                HelperCheckProgress(check: .signedIn, state: .waitingForSignIn, failure: nil, install: nil),
                key: F.key("report_request_progress"))
        },
        "report_request_result": ClientCall(path: ["id": F.id(F.request)]) {
            _ = try await $0.helper.reportRequestResult(
                requestID: F.request,
                HelperRequestResult(
                    outcome: .finished,
                    checks: [HelperCheckResult(check: .signedIn, passed: true, failure: nil)],
                    toolVersion: "1.0.0", plan: nil, accountEmail: nil),
                key: F.key("report_request_result"))
        },
        "issue_seat_token": ClientCall(path: ["id": F.id(F.request)]) {
            _ = try await $0.helper.issueSeatToken(requestID: F.request, key: F.key("issue_seat_token"))
        },
        "report_run_started": ClientCall(path: ["id": F.id(F.seat)]) {
            _ = try await $0.helper.reportRunStarted(
                seatID: F.seat,
                RunStartedReport(credentialID: F.credential, observedAt: F.observed, toolVersion: "1.0.0"),
                key: F.key("report_run_started"))
        },
        "report_run_stopped": ClientCall(path: ["id": F.id(F.seat)]) {
            _ = try await $0.helper.reportRunStopped(
                seatID: F.seat,
                RunStoppedReport(credentialID: F.credential, observedAt: F.observed, stopReason: .stopped),
                key: F.key("report_run_stopped"))
        },
    ]

    @Test("the clients have one method for each served operation, and no other")
    func coverage() {
        #expect(Set(Self.calls.keys) == Set(ContractDocument.served))
    }

    @Test("each client method sends its registry operation", arguments: ContractDocument.served)
    func sendsItsOperation(operation: String) async throws {
        let entry = try #require(ContractDocument.operation(operation))
        let call = try #require(Self.calls[operation], "no client method for \(operation)")
        let host = "op-\(operation.replacingOccurrences(of: "_", with: "-")).test"
        // The stub answers with the contract's first 200 example.
        let component = try #require(ContractDocument.responses(of: operation).first { $0.status == "200" }?.component)
        let example = try #require(ContractDocument.examples(of: component).first)
        let body = try ContractDocument.data(example)
        let session = StubURLProtocol.session(host: host, answer: .init(status: 200, body: body))

        try await call.call(Clients(baseURL: URL(string: "http://\(host):3000")!, session: session))

        let requests = StubURLProtocol.requests(host: host)
        #expect(requests.count == 1)
        let sent = try #require(requests.first)
        let method = try #require(entry["method"]?.stringValue)
        let caller = entry["caller"]?.stringValue
        let tag = entry["tag"]?.stringValue

        // Method and path.
        #expect(sent.method == method)
        var path = try #require(entry["path"]?.stringValue)
        for (name, value) in call.path {
            #expect(path.contains("{\(name)}"), "\(operation) has no {\(name)}")
            path = path.replacingOccurrences(of: "{\(name)}", with: value)
        }
        #expect(!path.contains("{"), "\(operation): a path parameter was not given")
        let url = try #require(sent.url)
        #expect(url.path == path)

        // Query: only the operation's own query parameters.
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        var query: [String: String] = [:]
        for item in items { query[item.name] = item.value }
        #expect(query == call.query)
        let parameters = ContractDocument.openAPIOperation(operation)?["parameters"]?.arrayValue ?? []
        let queryNames = Set(parameters.compactMap { $0["in"]?.stringValue == "query" ? $0["name"]?.stringValue : nil })
        #expect(Set(query.keys).isSubset(of: queryNames))

        // The key goes with every change and with nothing else.
        if method == "POST" {
            #expect(sent.header("Idempotency-Key") == "key-\(operation)")
        } else {
            #expect(sent.header("Idempotency-Key") == nil)
        }

        // The bearer token of the caller, except where no sign-in exists yet.
        let expectedToken: String? =
            switch (caller, tag) {
            case ("public", _): nil
            case (_, _) where operation == "sign_in_owner": nil
            case (_, "agent"): Fixture.seatToken
            case (_, "owner"): Fixture.ownerToken
            case (_, "helper"): Fixture.helperToken
            default: nil
            }
        #expect(sent.header("Authorization") == expectedToken.map { "Bearer \($0)" })

        // The body fits the operation's request schema.
        let requestSchemaRef = ContractDocument.openAPIOperation(operation)?["requestBody"]?["content"]?[
            "application/json"]?["schema"]?["$ref"]?.stringValue
        if let requestSchemaRef {
            let schemaName = try #require(ContractDocument.component(of: requestSchemaRef))
            let schema = try #require(ContractDocument.schema(schemaName))
            let bodyData = try #require(sent.body, "\(operation) sent no body")
            #expect(sent.header("Content-Type") == "application/json")
            let json = try JSONDecoder().decode(JSONValue.self, from: bodyData)
            Self.expect(json, fits: schema, at: schemaName)
            let text = String(decoding: bodyData, as: UTF8.self)
            #expect(text.range(of: "[0-9A-F]{8}-[0-9A-F]{4}-", options: .regularExpression) == nil,
                    "\(operation) sent an upper-case id: \(text)")
        } else {
            #expect(sent.body == nil || sent.body?.isEmpty == true, "\(operation) sent a body")
        }
    }

    /// The object's keys are the schema's properties, every required one
    /// present, a null only where the property allows it; nested objects and
    /// arrays of objects are checked the same way.
    static func expect(_ value: JSONValue, fits schema: JSONValue, at place: String) {
        var schema = schema
        if let ref = schema["$ref"]?.stringValue, let name = ContractDocument.component(of: ref),
           let resolved = ContractDocument.schema(name) {
            schema = resolved
        }
        guard case .object(let object) = value, let properties = schema["properties"]?.objectValue else {
            if case .array(let elements) = value, let items = schema["items"] {
                for element in elements { expect(element, fits: items, at: "\(place)[]") }
            }
            return
        }
        let required = (schema["required"]?.arrayValue ?? []).compactMap(\.stringValue)
        for name in required {
            #expect(object[name] != nil, "\(place) lacks the required \(name)")
        }
        for (name, field) in object {
            guard let property = properties[name] else {
                Issue.record("\(place) has \(name), which its schema does not")
                continue
            }
            if field == .null {
                let types = property["type"]?.arrayValue?.compactMap(\.stringValue)
                    ?? property["type"]?.stringValue.map { [$0] } ?? []
                let anyOfNull = property["anyOf"]?.arrayValue?.contains { $0["type"]?.stringValue == "null" } ?? false
                #expect(types.contains("null") || anyOfNull, "\(place).\(name) is null, which its schema refuses")
            }
            if let allowed = property["enum"]?.arrayValue, field != .null {
                #expect(allowed.contains(field), "\(place).\(name) = \(field) is not in its enum")
            }
            if let constant = property["const"] {
                #expect(field == constant, "\(place).\(name) must be \(constant)")
            }
            expect(field, fits: property, at: "\(place).\(name)")
        }
    }

    @Test("an owner client issues the helper's token for the app services")
    func helperTokenIssuing() async throws {
        let shown = StubURLProtocol.session(host: "issue-shown.test", answer: .init(status: 200, json: """
            {"key":"k","command":"issue_helper_token","outcome":"completed",
             "result":{"helper_id":"00000000-0000-4000-8000-000000000001","helper_token":"lvh_made-up"},
             "refusal":null}
            """))
        let issuer: any HelperTokenIssuing = OwnerClient(
            baseURL: URL(string: "http://issue-shown.test")!, sessionToken: Fixture.ownerToken, session: shown)
        let token = try await issuer.issueHelperToken(name: "This Mac", idempotencyKey: "key-1")
        #expect(token == "lvh_made-up")
        let sent = try #require(StubURLProtocol.requests(host: "issue-shown.test").first)
        #expect(sent.header("Idempotency-Key") == "key-1")

        let repeated = StubURLProtocol.session(host: "issue-repeated.test", answer: .init(status: 200, json: """
            {"key":"k","command":"issue_helper_token","outcome":"completed",
             "result":{"helper_id":"00000000-0000-4000-8000-000000000001","repeated":true},"refusal":null}
            """))
        let again = OwnerClient(
            baseURL: URL(string: "http://issue-repeated.test")!, sessionToken: Fixture.ownerToken, session: repeated)
        #expect(try await again.issueHelperToken(name: "This Mac", idempotencyKey: "key-1") == nil)

        await #expect(throws: LeverageClientError.invalidKey("not a key")) {
            _ = try await again.issueHelperToken(name: "This Mac", idempotencyKey: "not a key")
        }
    }
}
