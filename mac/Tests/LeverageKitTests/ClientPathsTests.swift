import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
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
    static let job = UUID(uuidString: "00000000-0000-4000-8000-0000000000A7")!
    static let rule = UUID(uuidString: "00000000-0000-4000-8000-0000000000A8")!
    static let check = UUID(uuidString: "00000000-0000-4000-8000-0000000000A9")!
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
        "get_join": ClientCall(query: ["connection": "mcp"]) {
            _ = try await $0.agent.join(connection: .mcp)
        },
        "get_next": ClientCall(query: ["wait": "30"]) { _ = try await $0.agent.next(wait: 30) },
        "get_command": ClientCall(path: ["key": "key-get_command"]) {
            _ = try await $0.agent.command(key: F.key("get_command"))
        },
        "create_task": ClientCall {
            _ = try await $0.agent.createTask(
                CreateTaskRequest(
                    title: "Check invoices", details: "Use the sample invoices",
                    criteria: [CriterionInput(text: "Review totals", kind: .review)],
                    projectID: F.task, priority: .high, workReference: "https://example.invalid/invoices"),
                key: F.key("create_task"))
        },
        "report_model": ClientCall {
            _ = try await $0.agent.reportModel(
                ReportModelRequest(model: "claude-opus-5-5", effort: "high"), key: F.key("report_model"))
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
        "get_owner_identity": ClientCall { _ = try await $0.owner.ownerIdentity() },
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
        "add_task": ClientCall {
            _ = try await $0.owner.addTask(
                AddTaskRequest(
                    title: "Made-up task", priority: .normal, workReference: nil,
                    state: .backlog),
                key: F.key("add_task"))
        },
        "complete_contract": ClientCall(path: ["id": F.id(F.task)]) {
            _ = try await $0.owner.completeContract(
                taskID: F.task,
                CompleteContractRequest(
                    title: "Made-up task", details: nil,
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
        "issue_landing_prompt": ClientCall(path: ["id": F.id(F.seat)]) {
            _ = try await $0.owner.issueLandingPrompt(
                seatID: F.seat, connection: .mcp, key: F.key("issue_landing_prompt"))
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
        "rename_credential": ClientCall(path: ["id": F.id(F.credential)]) {
            _ = try await $0.owner.renameCredential(
                credentialID: F.credential, RenameCredentialRequest(name: "Renamed login"), key: F.key("rename_credential"))
        },
        "remove_credential": ClientCall(path: ["id": F.id(F.credential)]) {
            _ = try await $0.owner.removeCredential(credentialID: F.credential, key: F.key("remove_credential"))
        },
        "refresh_usage": ClientCall {
            let result = try await $0.owner.refreshUsage(key: F.key("refresh_usage")).completedResult()
            #expect(result?.helperRequestIDs == [F.request])
        },
        "verify_all_credentials": ClientCall {
            let result = try await $0.owner.verifyAllCredentials(key: F.key("verify_all_credentials")).completedResult()
            #expect(result?.helperRequestIDs == [F.request])
        },
        "reorder_credentials": ClientCall {
            _ = try await $0.owner.reorderCredentials(
                ReorderCredentialsRequest(order: [F.credential, F.seat]), key: F.key("reorder_credentials"))
        },
        "report_reading": ClientCall(path: ["id": F.id(F.credential)]) {
            let figure = Figure(label: "Requests remaining", kind: .allowance, window: nil,
                                percentUsed: nil, resetAt: nil, value: .number(0))
            let reading = CredentialReading(credentialID: F.credential, observedAt: F.observed, state: .ok,
                                            toolVersion: nil, figures: [figure], resets: nil)
            _ = try await $0.helper.reportReading(credentialID: F.credential, reading, key: F.key("report_reading"))
        },
        "install_tool": ClientCall(path: ["provider": "codex"]) {
            _ = try await $0.owner.installTool(provider: .codex, key: F.key("install_tool"))
        },
        // Owner, Handoff milestone
        "list_inbox": ClientCall(query: ["after_seq": "7", "wait": "30"]) {
            _ = try await $0.owner.listInbox(afterSeq: 7, wait: 30)
        },
        "sign_in_again": ClientCall(path: ["id": F.id(F.credential)]) {
            _ = try await $0.owner.signInAgain(credentialID: F.credential, key: F.key("sign_in_again"))
        },
        "promote_task": ClientCall(path: ["id": F.id(F.task)]) {
            _ = try await $0.owner.promoteTask(taskID: F.task, key: F.key("promote_task"))
        },
        "edit_contract": ClientCall(path: ["id": F.id(F.task)]) {
            _ = try await $0.owner.editContract(
                taskID: F.task,
                CompleteContractRequest(
                    title: "Made-up task", details: nil,
                    criteria: [CriterionInput(text: "It works", kind: .build)], actions: [],
                    minimumStrengthRank: nil, budgetCap: nil, workReference: nil),
                key: F.key("edit_contract"))
        },
        "hold_task": ClientCall(path: ["id": F.id(F.task)]) {
            _ = try await $0.owner.holdTask(taskID: F.task, key: F.key("hold_task"))
        },
        "resume_task": ClientCall(path: ["id": F.id(F.task)]) {
            _ = try await $0.owner.resumeTask(taskID: F.task, key: F.key("resume_task"))
        },
        "pause_seat": ClientCall(path: ["id": F.id(F.seat)]) {
            _ = try await $0.owner.pauseSeat(seatID: F.seat, key: F.key("pause_seat"))
        },
        "resume_seat": ClientCall(path: ["id": F.id(F.seat)]) {
            _ = try await $0.owner.resumeSeat(seatID: F.seat, key: F.key("resume_seat"))
        },
        "change_seat": ClientCall(path: ["id": F.id(F.seat)]) {
            _ = try await $0.owner.changeSeat(
                seatID: F.seat,
                ChangeSeatRequest(
                    name: "Made-up builder", role: .reviewer, model: .set("made-up-model"), effort: .clear,
                    strengthRank: .set(2), credentialID: .set(F.credential), enabled: true),
                key: F.key("change_seat"))
        },
        // Agent and owner, Rule checks milestone
        "claim_next_job": ClientCall { _ = try await $0.agent.claimNextJob(key: F.key("claim_next_job")) },
        "submit_job_result": ClientCall(path: ["id": F.id(F.job)]) {
            _ = try await $0.agent.submitJobResult(
                jobID: F.job,
                JobResultRequest(
                    result: .ruleCheck(RuleCheckVerdict(result: .failed, reason: "Made-up reason.")),
                    tokens: 120, spend: 0),
                key: F.key("submit_job_result"))
        },
        "list_rules": ClientCall { _ = try await $0.owner.listRules() },
        "add_rule": ClientCall {
            _ = try await $0.owner.addRule(
                AddRuleRequest(
                    name: "Made-up rule", instruction: "Every task names its page.", hook: .taskBeforeReady,
                    scope: .checkerDecides),
                key: F.key("add_rule"))
        },
        "save_rule": ClientCall(path: ["id": F.id(F.rule)]) {
            _ = try await $0.owner.saveRule(
                ruleID: F.rule,
                SaveRuleRequest(
                    name: "Made-up rule", instruction: "Every task names its page.", scope: .allTasks,
                    onFail: .block, route: .builder),
                key: F.key("save_rule"))
        },
        "enable_rule": ClientCall(path: ["id": F.id(F.rule)]) {
            _ = try await $0.owner.enableRule(ruleID: F.rule, key: F.key("enable_rule"))
        },
        "disable_rule": ClientCall(path: ["id": F.id(F.rule)]) {
            _ = try await $0.owner.disableRule(ruleID: F.rule, key: F.key("disable_rule"))
        },
        "revert_rule": ClientCall(path: ["id": F.id(F.rule)]) {
            _ = try await $0.owner.revertRule(ruleID: F.rule, key: F.key("revert_rule"))
        },
        "remove_rule": ClientCall(path: ["id": F.id(F.rule)]) {
            _ = try await $0.owner.removeRule(ruleID: F.rule, key: F.key("remove_rule"))
        },
        "rerun_check": ClientCall(path: ["id": F.id(F.check)]) {
            _ = try await $0.owner.rerunCheck(checkID: F.check, key: F.key("rerun_check"))
        },
        "override_check": ClientCall(path: ["id": F.id(F.check)]) {
            _ = try await $0.owner.overrideCheck(
                checkID: F.check, OverrideCheckRequest(reason: "Made-up reason."), key: F.key("override_check"))
        },
        "draft_contract": ClientCall(path: ["id": F.id(F.task)]) {
            _ = try await $0.owner.draftContract(taskID: F.task, key: F.key("draft_contract"))
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
        "report_limit": ClientCall(path: ["id": F.id(F.credential)]) {
            _ = try await $0.helper.reportLimit(
                credentialID: F.credential,
                LimitReport(
                    credentialID: F.credential, seatID: F.seat, work: .task(F.task), window: .fiveHour,
                    resetAt: F.observed, observedAt: F.observed, toolVersion: "1.0.0"),
                key: F.key("report_limit"))
        },
        "report_signed_out": ClientCall(path: ["id": F.id(F.credential)]) {
            _ = try await $0.helper.reportSignedOut(
                credentialID: F.credential,
                SignOutReport(
                    credentialID: F.credential, seatID: F.seat, work: .review(F.review), observedAt: F.observed,
                    toolVersion: "1.0.0"),
                key: F.key("report_signed_out"))
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
        let milestoneFive = QuestionsAndApprovalsClientTests.calls.map(\.operation)
        #expect(Set(milestoneFive) == Set(ContractDocument.questionsAndApprovals))
        #expect(Set(Self.calls.keys).isDisjoint(with: milestoneFive))
        #expect(Set(Self.calls.keys).union(milestoneFive) == Set(ContractDocument.served))
    }

    @Test("join defaults to HTTP through the agent API")
    func joinDefaultsToHTTP() async throws {
        let host = "join-default.test"
        let example = try #require(ContractDocument.examples(of: "JoinInstructions").first)
        let session = StubURLProtocol.session(
            host: host, answer: .init(status: 200, body: try ContractDocument.data(example)))
        let agent: any AgentAPI = Clients(baseURL: URL(string: "http://\(host)")!, session: session).agent

        let instructions = try await agent.join()

        #expect(instructions.connection == .http)
        #expect(instructions.role == .general)
        #expect(instructions.text == example["text"]?.stringValue)
        let sent = try #require(StubURLProtocol.requests(host: host).first)
        #expect(sent.method == "GET")
        #expect(sent.url?.path == "/v1/join")
        #expect(sent.url?.query == nil)
    }

    @Test("agent and helper polls give the server its requested wait and a timeout margin",
          arguments: [nil, 0, 12] as [Int?])
    func nextTimeout(wait: Int?) async throws {
        let host = "next-timeout-\(wait.map(String.init) ?? "default").test"
        let session = StubURLProtocol.session(host: host, answers: [
            .init(status: 200, json: #"{"kind":"none","id":null,"review_id":null}"#),
            .init(status: 200, json: #"{"request":null}"#),
        ])
        let clients = Clients(baseURL: URL(string: "http://\(host)")!, session: session)

        let item = try await clients.agent.next(wait: wait)
        let next = try await clients.helper.next(wait: wait)
        #expect(item.kind == .none)
        #expect(next.request == nil)

        let requests = StubURLProtocol.requests(host: host)
        #expect(requests.count == 2)
        let expectedWait = wait ?? 30 // IF-14 sets the server default for both operations.
        for sent in requests {
            let query = sent.url?.query
            #expect(query == "wait=\(expectedWait)" || (query == nil && wait == nil))
            #expect(sent.request.timeoutInterval >= TimeInterval(expectedWait) + HTTPTransport.longPollMargin)
        }
    }

    @Test("each client method sends its registry operation", arguments: Self.calls.keys.sorted())
    func sendsItsOperation(operation: String) async throws {
        let entry = try #require(ContractDocument.operation(operation))
        let call = try #require(Self.calls[operation], "no client method for \(operation)")
        let host = "op-\(operation.replacingOccurrences(of: "_", with: "-")).test"
        // The stub answers with the contract's first 200 example.
        let component = try #require(ContractDocument.responses(of: operation).first { $0.status == "200" }?.component)
        var example = try #require(ContractDocument.examples(of: component).first)
        if operation == "refresh_usage" || operation == "verify_all_credentials" {
            // These operations specify the result in prose rather than in a separate schema.
            var fields = try #require(example.objectValue)
            let command = try #require(entry["commands"]?.arrayValue?.first)
            fields["command"] = command
            fields["result"] = .object(["helper_request_ids": .array([.string(F.id(F.request))])])
            example = .object(fields)
        }
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
            if operation == "issue_landing_prompt" {
                #expect(json == .object(["connection": .string("mcp")]))
            }
            if operation == "reorder_credentials" {
                #expect(json["order"]?.arrayValue == [.string(F.id(F.credential)), .string(F.id(F.seat))])
            }
            let text = String(decoding: bodyData, as: UTF8.self)
            let ids = text.matches(of: /[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}/)
            for id in ids {
                #expect(id.output == id.output.lowercased(), "\(operation) sent an upper-case id: \(text)")
            }
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

@Suite("Fake APIs")
struct FakeAPITests {
    @Test("a fake throws for what was not scripted, answers what was, and records each call")
    func ownerFake() async throws {
        let fake = FakeOwnerAPI()
        await #expect(throws: FakeAPIError.notScripted(.getBoard)) { _ = try await fake.board() }

        let board = Board(tasks: [], asOfSeq: 7, reviewerSeatExists: false)
        fake.script { $0.board = { board } }
        #expect(try await fake.board() == board)

        let task = UUID(uuidString: "00000000-0000-4000-8000-0000000000B1")!
        let key = IdempotencyKey()
        fake.script { $0.cancelTask = { _, key in .completed(.object([:]), key: key.value, command: .cancel) } }
        let outcome = try await fake.cancelTask(taskID: task, key: key)
        #expect(outcome.outcome == .completed)
        #expect(fake.calls == [
            FakeCall(.getBoard), FakeCall(.getBoard),
            FakeCall(.cancelTask, path: ["id": "00000000-0000-4000-8000-0000000000b1"], key: key),
        ])
    }

    @Test("a fake records the body the HTTP client sends")
    func fakeBodyMatchesClient() async throws {
        let request = AddTaskRequest(title: "Made-up task", priority: .high, state: .backlog)
        let key = IdempotencyKey()
        let fake = FakeOwnerAPI()
        fake.script { $0.addTask = { _, key in
            .completed(TaskCreatedResult(taskID: UUID()), key: key.value, command: .addTask)
        } }
        _ = try await fake.addTask(request, key: key)

        let session = StubURLProtocol.session(host: "fake-parity.test", answer: .init(status: 200, json: """
            {"key":"k","command":"add_task","outcome":"completed",
             "result":{"task_id":"00000000-0000-4000-8000-000000000001"},"refusal":null}
            """))
        let client = OwnerClient(baseURL: URL(string: "http://fake-parity.test")!, sessionToken: "lvo_x", session: session)
        _ = try await client.addTask(request, key: key)
        let sent = try #require(StubURLProtocol.requests(host: "fake-parity.test").first?.body)

        #expect(fake.calls.first?.body == (try JSONDecoder().decode(JSONValue.self, from: sent)))
        #expect(fake.calls.first?.key == key)
    }

    @Test("the agent and helper fakes record their calls")
    func agentAndHelperFakes() async throws {
        let agent = FakeAgentAPI()
        agent.script { $0.next = { _ in NextItem(kind: .none) } }
        #expect(try await agent.next(wait: 30) == NextItem(kind: .none))
        let task = UUID(), criterion = UUID(), key = IdempotencyKey()
        agent.script { $0.passCriterion = { _, _, _, key in .completed(nil, key: key.value, command: .passCriterion) } }
        _ = try await agent.passCriterion(
            taskID: task, criterionID: criterion, evidence: EvidenceInput(kind: .note, value: "n"), key: key)
        #expect(agent.calls.last == FakeCall(
            .passCriterion, path: ["id": task.contractString, "cid": criterion.contractString], key: key,
            body: .object(["evidence": .object(["kind": .string("note"), "value": .string("n")])])))

        let helper = FakeHelperAPI()
        await #expect(throws: FakeAPIError.notScripted(.issueSeatToken)) {
            _ = try await helper.issueSeatToken(requestID: UUID(), key: IdempotencyKey())
        }
        #expect(helper.calls.map(\.operation) == [.issueSeatToken])
    }

    @Test("the owner fake issues the helper's token like the client")
    func fakeIssuesHelperToken() async throws {
        let fake = FakeOwnerAPI()
        fake.script { $0.issueHelperToken = { _, key in
            .completed(.shown(HelperTokenIssued(helperID: UUID(), helperToken: "lvh_made-up")),
                       key: key.value, command: .issueHelperToken)
        } }
        let issuer: any HelperTokenIssuing = fake
        #expect(try await issuer.issueHelperToken(name: "This Mac", idempotencyKey: "key-1") == "lvh_made-up")
        #expect(fake.calls.first?.body == .object(["name": .string("This Mac")]))
    }

    @Test("a token answer never prints its token")
    func tokensArePrintedRemoved() {
        let session = OwnerSession(userID: UUID(), sessionToken: "lvo_secret-made-up", createdAt: Date())
        let pickup = SeatTokenPickup(helperRequestID: UUID(), seatID: UUID(), seatToken: "lvs_secret-made-up")
        let request = SignInRequest(emailAddress: "owner@example.invalid", password: "made-up-password")
        for text in [
            String(describing: session), String(reflecting: session), "\(pickup)",
            String(describing: request), String(reflecting: request),
            String(describing: OwnerSessionAnswer.shown(session)),
        ] {
            #expect(!text.contains("secret-made-up") && !text.contains("made-up-password")
                    && !text.contains("example.invalid"), "\(text)")
        }
        var dumped = ""
        dump(pickup, to: &dumped)
        #expect(!dumped.contains("secret-made-up"))
    }
}

@Suite("Rule check request bodies")
struct RuleCheckBodyTests {
    private static let rule = UUID(uuidString: "00000000-0000-4000-8000-0000000000A8")!
    private static let check = UUID(uuidString: "00000000-0000-4000-8000-0000000000A9")!
    private static let job = UUID(uuidString: "00000000-0000-4000-8000-0000000000A7")!
    private static let project = UUID(uuidString: "00000000-0000-4000-8000-0000000000B2")!

    private func json(_ body: some Encodable) throws -> JSONValue {
        try #require(FakeCall.json(body))
    }

    @Test("a scope writes all three of its keys, null where they do not apply, and its ids in lower case")
    func scope() throws {
        #expect(try json(RuleScope.allTasks) == .object([
            "kind": .string("all_tasks"), "project_ids": .null, "action_kinds": .null,
        ]))
        #expect(try json(RuleScope.checkerDecides)["kind"] == .string("checker_decides"))
        #expect(try json(RuleScope(kind: .namedProjects, projectIDs: [Self.project])) == .object([
            "kind": .string("named_projects"),
            "project_ids": .array([.string("00000000-0000-4000-8000-0000000000b2")]), "action_kinds": .null,
        ]))
        #expect(try json(RuleScope(kind: .actionKinds, actionKinds: [.publish, .pay])) == .object([
            "kind": .string("action_kinds"), "project_ids": .null,
            "action_kinds": .array([.string("publish"), .string("pay")]),
        ]))
    }

    @Test("Add rule sends its four fields and nothing else")
    func addRule() throws {
        let request = AddRuleRequest(
            name: "Made-up rule", instruction: "Every task names its page.", hook: .taskBeforeDone,
            scope: .checkerDecides)
        #expect(try json(request) == .object([
            "name": .string("Made-up rule"), "instruction": .string("Every task names its page."),
            "hook": .string("task.before_done"),
            "scope": .object(["kind": .string("checker_decides"), "project_ids": .null, "action_kinds": .null]),
        ]))
    }

    @Test("Save rule sends every field, the route among them, null where a field has none")
    func saveRule() throws {
        let request = SaveRuleRequest(
            name: "Made-up rule", instruction: nil, parameters: ["minimum": .number(2)], scope: .allTasks,
            onFail: .warn, route: .orchestrator, queueTimeoutSeconds: 60, runTimeoutSeconds: nil)
        let sent = try #require(json(request).objectValue)
        #expect(Set(sent.keys) == [
            "name", "instruction", "parameters", "scope", "on_fail", "route", "queue_timeout_seconds",
            "run_timeout_seconds",
        ])
        #expect(sent["instruction"] == .null && sent["run_timeout_seconds"] == .null)
        #expect(sent["parameters"] == .object(["minimum": .number(2)]))
        #expect(sent["on_fail"] == .string("warn") && sent["route"] == .string("orchestrator"))
        #expect(sent["queue_timeout_seconds"] == .number(60))
        let bare = try #require(json(SaveRuleRequest(
            name: "n", instruction: "i", scope: .allTasks, onFail: nil, route: nil)).objectValue)
        #expect(bare["on_fail"] == .null && bare["route"] == .null && bare["parameters"] == .null)
        #expect(bare.count == 8)
    }

    @Test("an override sends its reason")
    func override() throws {
        #expect(try json(OverrideCheckRequest(reason: "Made-up reason.")) == .object([
            "reason": .string("Made-up reason."),
        ]))
    }

    @Test("a checker's result goes in the fixed shape, with the tokens and the spend")
    func ruleCheckResult() throws {
        let request = JobResultRequest(
            result: .ruleCheck(RuleCheckVerdict(result: .notApplicable, reason: "Made-up reason.")), tokens: 340,
            spend: 0)
        #expect(try json(request) == .object([
            "result": .object(["result": .string("not_applicable"), "reason": .string("Made-up reason.")]),
            "tokens": .number(340), "spend": .number(0),
        ]))
        #expect(RuleCheckVerdict.reasonLimit == 500)
    }

    @Test("a planner's result is the Complete contract body, with the stored values sent back")
    func contractDraftResult() throws {
        let contract = CompleteContractRequest(
            title: "Made-up task", details: "Details.",
            criteria: [CriterionInput(text: "It works", kind: .build), CriterionInput(text: "Checked", kind: .review)],
            actions: [], minimumStrengthRank: 2, budgetCap: 5, workReference: "/made/up")
        let sent = try #require(json(JobResultRequest(result: .contractDraft(contract), tokens: 1, spend: 0)).objectValue)
        let result = try #require(sent["result"]?.objectValue)
        #expect(Set(result.keys) == [
            "title", "details", "criteria", "actions", "minimum_strength_rank", "budget_cap",
            "work_reference",
        ])
        #expect(result["minimum_strength_rank"] == .number(2) && result["work_reference"] == .string("/made/up"))
        #expect(result["criteria"]?[1]?["kind"] == .string("review"))
    }

    @Test("the fakes record the bodies the HTTP clients send")
    func fakesMatchTheClients() async throws {
        let ruleKey = IdempotencyKey(), overrideKey = IdempotencyKey(), resultKey = IdempotencyKey()
        let save = SaveRuleRequest(
            name: "Made-up rule", instruction: "Every task names its page.", scope: .allTasks, onFail: .block,
            route: .builder)
        let override = OverrideCheckRequest(reason: "Made-up reason.")
        let result = JobResultRequest(
            result: .ruleCheck(RuleCheckVerdict(result: .passed, reason: "Made-up reason.")), tokens: 5, spend: 0)

        let owner = FakeOwnerAPI()
        let done: @Sendable (UUID, IdempotencyKey) async throws -> PlainOutcome = { _, key in
            .completed(.object([:]), key: key.value, command: .saveRule)
        }
        owner.script {
            $0.saveRule = { _, _, key in .completed(.object([:]), key: key.value, command: .saveRule) }
            $0.overrideCheck = { _, _, key in .completed(.object([:]), key: key.value, command: .overrideCheck) }
            $0.enableRule = done; $0.disableRule = done; $0.revertRule = done; $0.removeRule = done
            $0.rerunCheck = done
            $0.draftContract = { _, key in
                .completed(DraftContractResult(jobID: Self.job), key: key.value, command: .draftContract)
            }
            $0.listRules = { RulesList(rules: []) }
        }
        _ = try await owner.saveRule(ruleID: Self.rule, save, key: ruleKey)
        _ = try await owner.overrideCheck(checkID: Self.check, override, key: overrideKey)
        let agent = FakeAgentAPI()
        agent.script { $0.submitJobResult = { _, _, key in .completed(nil, key: key.value, command: .submitJobResult) } }
        _ = try await agent.submitJobResult(jobID: Self.job, result, key: resultKey)

        let outcome = #"{"key":"k","command":"save_rule","outcome":"completed","result":null,"refusal":null}"#
        let ownerSession = StubURLProtocol.session(host: "rule-fake-owner.test", answer: .init(status: 200, json: outcome))
        let agentSession = StubURLProtocol.session(host: "rule-fake-agent.test", answer: .init(status: 200, json: outcome))
        let ownerClient = OwnerClient(
            baseURL: URL(string: "http://rule-fake-owner.test")!, sessionToken: "lvo_x", session: ownerSession)
        _ = try await ownerClient.saveRule(ruleID: Self.rule, save, key: ruleKey)
        _ = try await ownerClient.overrideCheck(checkID: Self.check, override, key: overrideKey)
        _ = try await AgentClient(
            baseURL: URL(string: "http://rule-fake-agent.test")!, seatToken: "lvs_x", session: agentSession)
            .submitJobResult(jobID: Self.job, result, key: resultKey)

        let sentToOwner = StubURLProtocol.requests(host: "rule-fake-owner.test").compactMap(\.body)
        let sentToAgent = try #require(StubURLProtocol.requests(host: "rule-fake-agent.test").first?.body)
        let sentSave = try #require(sentToOwner.first)
        let sentOverride = try #require(sentToOwner.dropFirst().first)
        let ownerCalls = owner.calls
        let savedCall = try #require(ownerCalls.first)
        let overrideCall = try #require(ownerCalls.dropFirst().first)
        #expect(sentToOwner.count == 2 && ownerCalls.count == 2)
        #expect(savedCall.body == (try JSONDecoder().decode(JSONValue.self, from: sentSave)))
        #expect(overrideCall.body == (try JSONDecoder().decode(JSONValue.self, from: sentOverride)))
        #expect(agent.calls.first?.body == (try JSONDecoder().decode(JSONValue.self, from: sentToAgent)))
        #expect(savedCall == FakeCall(
            .saveRule, path: ["id": "00000000-0000-4000-8000-0000000000a8"], key: ruleKey, body: savedCall.body))
        #expect(overrideCall.path == ["id": "00000000-0000-4000-8000-0000000000a9"])
        #expect(agent.calls.first?.path == ["id": "00000000-0000-4000-8000-0000000000a7"])
    }

    @Test("the fakes record each new call with its path and key, and refuse what was not scripted")
    func fakesRecord() async throws {
        let owner = FakeOwnerAPI()
        let key = IdempotencyKey()
        let done: @Sendable (UUID, IdempotencyKey) async throws -> PlainOutcome = { _, key in
            .completed(.object([:]), key: key.value, command: .enableRule)
        }
        owner.script {
            $0.enableRule = done; $0.disableRule = done; $0.revertRule = done; $0.removeRule = done
            $0.rerunCheck = done
            $0.addRule = { _, key in .completed(.object([:]), key: key.value, command: .addRule) }
            $0.draftContract = { _, key in
                .completed(DraftContractResult(jobID: Self.job), key: key.value, command: .draftContract)
            }
            $0.listRules = { RulesList(rules: []) }
        }
        _ = try await owner.enableRule(ruleID: Self.rule, key: key)
        _ = try await owner.disableRule(ruleID: Self.rule, key: key)
        _ = try await owner.revertRule(ruleID: Self.rule, key: key)
        _ = try await owner.removeRule(ruleID: Self.rule, key: key)
        _ = try await owner.rerunCheck(checkID: Self.check, key: key)
        _ = try await owner.addRule(
            AddRuleRequest(name: "n", instruction: "i", hook: .taskBeforeReady, scope: .allTasks), key: key)
        let drafted = try await owner.draftContract(taskID: UUID(), key: key)
        #expect(drafted.result == DraftContractResult(jobID: Self.job))
        #expect(try await owner.listRules() == RulesList(rules: []))
        #expect(owner.calls.map(\.operation) == [
            .enableRule, .disableRule, .revertRule, .removeRule, .rerunCheck, .addRule, .draftContract, .listRules,
        ])
        await #expect(throws: FakeAPIError.notScripted(.saveRule)) {
            _ = try await owner.saveRule(
                ruleID: Self.rule,
                SaveRuleRequest(name: "n", instruction: nil, scope: .allTasks, onFail: nil, route: nil), key: key)
        }
        await #expect(throws: FakeAPIError.notScripted(.overrideCheck)) {
            _ = try await owner.overrideCheck(checkID: Self.check, OverrideCheckRequest(reason: "r"), key: key)
        }
        let agent = FakeAgentAPI()
        await #expect(throws: FakeAPIError.notScripted(.claimNextJob)) { _ = try await agent.claimNextJob(key: key) }
        await #expect(throws: FakeAPIError.notScripted(.submitJobResult)) {
            _ = try await agent.submitJobResult(
                jobID: Self.job,
                JobResultRequest(result: .ruleCheck(RuleCheckVerdict(result: .passed, reason: "r"))), key: key)
        }
        #expect(agent.calls.map(\.operation) == [.claimNextJob, .submitJobResult])
    }
}

@Suite("Handoff request bodies")
struct HandoffBodyTests {
    private static let credential = UUID(uuidString: "00000000-0000-4000-8000-0000000000A5")!
    private static let seat = UUID(uuidString: "00000000-0000-4000-8000-0000000000A4")!
    private static let task = UUID(uuidString: "00000000-0000-4000-8000-0000000000A1")!
    private static let review = UUID(uuidString: "00000000-0000-4000-8000-0000000000A3")!
    private static let job = UUID(uuidString: "00000000-0000-4000-8000-0000000000A7")!
    private static let observed = Date(timeIntervalSince1970: 1_767_225_600)
    private static let reset = Date(timeIntervalSince1970: 1_767_243_600)

    private func json(_ body: some Encodable) throws -> JSONValue {
        try #require(FakeCall.json(body))
    }

    @Test("a limit report names its work, its window and its reset time, and nothing the tool said")
    func limitReport() throws {
        let report = LimitReport(
            credentialID: Self.credential, seatID: Self.seat, work: .task(Self.task), window: .weekly,
            resetAt: Self.reset, observedAt: Self.observed, toolVersion: "1.2.3")
        #expect(try json(report) == .object([
            "credential_id": .string("00000000-0000-4000-8000-0000000000a5"),
            "seat_id": .string("00000000-0000-4000-8000-0000000000a4"),
            "task_id": .string("00000000-0000-4000-8000-0000000000a1"),
            "review_id": .null, "job_id": .null,
            "window": .string("weekly"), "reset_at": .string("2026-01-01T05:00:00Z"),
            "observed_at": .string("2026-01-01T00:00:00Z"), "tool_version": .string("1.2.3"),
        ]))
    }

    @Test("a limit with no reset time sends null, a review and a job each go in their own field")
    func limitReportWork() throws {
        func fields(_ work: InterruptedWork) throws -> [String: JSONValue] {
            let report = LimitReport(
                credentialID: Self.credential, seatID: Self.seat, work: work, window: .spend, resetAt: nil,
                observedAt: Self.observed, toolVersion: "1.2.3")
            return try #require(json(report).objectValue)
        }
        let review = try fields(.review(Self.review))
        #expect(review["reset_at"] == .null && review["window"] == .string("spend"))
        #expect(review["review_id"] == .string("00000000-0000-4000-8000-0000000000a3"))
        #expect(review["task_id"] == .null && review["job_id"] == .null)
        let job = try fields(.job(Self.job))
        #expect(job["job_id"] == .string("00000000-0000-4000-8000-0000000000a7"))
        #expect(job["task_id"] == .null && job["review_id"] == .null)
    }

    @Test("a sign-out report has no window and no reset time")
    func signOutReport() throws {
        let report = SignOutReport(
            credentialID: Self.credential, seatID: Self.seat, work: .review(Self.review),
            observedAt: Self.observed, toolVersion: "1.2.3")
        #expect(try json(report) == .object([
            "credential_id": .string("00000000-0000-4000-8000-0000000000a5"),
            "seat_id": .string("00000000-0000-4000-8000-0000000000a4"),
            "task_id": .null, "review_id": .string("00000000-0000-4000-8000-0000000000a3"), "job_id": .null,
            "observed_at": .string("2026-01-01T00:00:00Z"), "tool_version": .string("1.2.3"),
        ]))
    }

    @Test("a seat change sends only what the owner changed")
    func changeSeatSendsWhatChanged() throws {
        #expect(try json(ChangeSeatRequest()) == .object([:]))
        #expect(try json(ChangeSeatRequest(name: "Renamed")) == .object(["name": .string("Renamed")]))
        #expect(try json(ChangeSeatRequest(enabled: false)) == .object(["enabled": .bool(false)]))
        #expect(try json(ChangeSeatRequest(role: .planner)) == .object(["role": .string("planner")]))
    }

    @Test("a seat change can set a field, and clear one that may be null")
    func changeSeatSetsAndClears() throws {
        let request = ChangeSeatRequest(
            model: .clear, effort: .set("high"), strengthRank: .set(0), credentialID: .set(Self.credential))
        #expect(try json(request) == .object([
            "model": .null, "effort": .string("high"), "strength_rank": .number(0),
            "credential_id": .string("00000000-0000-4000-8000-0000000000a5"),
        ]))
        #expect(try json(ChangeSeatRequest(credentialID: .clear)) == .object(["credential_id": .null]))
        #expect(try json(ChangeSeatRequest(strengthRank: .clear)) == .object(["strength_rank": .null]))
    }

    @Test("a fake records the body the HTTP client sends for a seat change and a limit report")
    func fakesMatchTheClients() async throws {
        let seatKey = IdempotencyKey(), limitKey = IdempotencyKey()
        let change = ChangeSeatRequest(name: "Renamed", model: .clear, credentialID: .set(Self.credential))
        let limit = LimitReport(
            credentialID: Self.credential, seatID: Self.seat, work: .task(Self.task), window: .fiveHour,
            resetAt: nil, observedAt: Self.observed, toolVersion: "1.2.3")

        let owner = FakeOwnerAPI()
        owner.script { $0.changeSeat = { _, _, key in .completed(.object([:]), key: key.value, command: .changeSeat) } }
        _ = try await owner.changeSeat(seatID: Self.seat, change, key: seatKey)
        let helper = FakeHelperAPI()
        helper.script { $0.reportLimit = { _, _, key in .completed(nil, key: key.value, command: .reportLimit) } }
        _ = try await helper.reportLimit(credentialID: Self.credential, limit, key: limitKey)

        let outcome = #"{"key":"k","command":"change_seat","outcome":"completed","result":null,"refusal":null}"#
        let ownerSession = StubURLProtocol.session(host: "handoff-fake-owner.test", answer: .init(status: 200, json: outcome))
        let helperSession = StubURLProtocol.session(host: "handoff-fake-helper.test", answer: .init(status: 200, json: outcome))
        _ = try await OwnerClient(
            baseURL: URL(string: "http://handoff-fake-owner.test")!, sessionToken: "lvo_x", session: ownerSession)
            .changeSeat(seatID: Self.seat, change, key: seatKey)
        _ = try await HelperClient(
            baseURL: URL(string: "http://handoff-fake-helper.test")!, helperToken: "lvh_x", session: helperSession)
            .reportLimit(credentialID: Self.credential, limit, key: limitKey)

        let sentToOwner = try #require(StubURLProtocol.requests(host: "handoff-fake-owner.test").first?.body)
        let sentToHelper = try #require(StubURLProtocol.requests(host: "handoff-fake-helper.test").first?.body)
        #expect(owner.calls.first?.body == (try JSONDecoder().decode(JSONValue.self, from: sentToOwner)))
        #expect(helper.calls.first?.body == (try JSONDecoder().decode(JSONValue.self, from: sentToHelper)))
        #expect(owner.calls.first == FakeCall(
            .changeSeat, path: ["id": "00000000-0000-4000-8000-0000000000a4"], key: seatKey, body: owner.calls.first?.body))
        #expect(helper.calls.first?.path == ["id": "00000000-0000-4000-8000-0000000000a5"])
    }

    @Test("the owner fake records each new command with its path and key")
    func ownerFakeRecords() async throws {
        let fake = FakeOwnerAPI()
        let key = IdempotencyKey()
        let done: @Sendable (UUID, IdempotencyKey) async throws -> PlainOutcome = { _, key in
            .completed(.object([:]), key: key.value, command: .cancel)
        }
        fake.script {
            $0.promoteTask = done; $0.holdTask = done; $0.resumeTask = done; $0.pauseSeat = done
            $0.resumeSeat = done; $0.signInAgain = done
            $0.listInbox = { _, _ in InboxPage(items: [], nextAfterSeq: 4) }
        }
        _ = try await fake.promoteTask(taskID: Self.task, key: key)
        _ = try await fake.holdTask(taskID: Self.task, key: key)
        _ = try await fake.resumeTask(taskID: Self.task, key: key)
        _ = try await fake.pauseSeat(seatID: Self.seat, key: key)
        _ = try await fake.resumeSeat(seatID: Self.seat, key: key)
        _ = try await fake.signInAgain(credentialID: Self.credential, key: key)
        #expect(try await fake.listInbox(afterSeq: 3, wait: nil).nextAfterSeq == 4)
        #expect(fake.calls.map(\.operation) == [
            .promoteTask, .holdTask, .resumeTask, .pauseSeat, .resumeSeat, .signInAgain, .listInbox,
        ])
        #expect(fake.calls.dropLast().map(\.key) == Array(repeating: key, count: 6))
        await #expect(throws: FakeAPIError.notScripted(.editContract)) {
            _ = try await fake.editContract(
                taskID: Self.task,
                CompleteContractRequest(title: "t", details: nil, criteria: [], workReference: nil),
                key: key)
        }
        await #expect(throws: FakeAPIError.notScripted(.changeSeat)) {
            _ = try await fake.changeSeat(seatID: Self.seat, ChangeSeatRequest(), key: key)
        }
        let helper = FakeHelperAPI()
        await #expect(throws: FakeAPIError.notScripted(.reportSignedOut)) {
            _ = try await helper.reportSignedOut(
                credentialID: Self.credential,
                SignOutReport(
                    credentialID: Self.credential, seatID: Self.seat, work: .task(Self.task),
                    observedAt: Self.observed, toolVersion: "1"),
                key: key)
        }
    }
}
