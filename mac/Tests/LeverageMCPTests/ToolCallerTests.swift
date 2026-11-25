import Foundation
import LeverageKit
import Testing
@testable import LeverageMCP

struct ToolCallerTests {
    private let catalog = ToolCatalog(role: .builder)

    @Test func forwardsBodyWithoutPathOrControlArgumentsAndReturnsTheKey() async throws {
        let fake = RecordingTransport()
        let caller = ToolCaller(transport: fake.send)
        let tool = try #require(catalog.tool(named: "ask_question"))
        let body: [String: JSONValue] = ["text": .string("fixture question"),
                                        "assumption": .string("fixture assumption"), "blocking": .bool(false)]
        var args = body
        args["id"] = .string(taskID)
        let first = await caller.call(tool, arguments: args)
        let key = try #require(first.key)
        args["idempotency_key"] = .string(key.value)
        let repeatResult = await caller.call(tool, arguments: args)
        #expect(first.isError == false)
        #expect(repeatResult.key == key)
        let requests = await fake.requests
        let sendsIdenticalRequests = requests == Array(repeating: ToolRequest(
            operation: .askQuestion, path: ["id": taskID], body: body, key: key), count: 2)
        #expect(sendsIdenticalRequests)
    }

    @Test func reportsModelAndCreatesTaskWithTheGeneratedTools() async throws {
        let fake = RecordingTransport()
        let caller = ToolCaller(transport: fake.send)
        let report = try #require(catalog.tool(named: "report_model"))
        let create = try #require(catalog.tool(named: "create_task"))
        let reportBody: [String: JSONValue] = ["model": .null, "effort": .null]
        let createBody: [String: JSONValue] = [
            "title": .string("Check the totals"), "criteria": .array([.object([
                "text": .string("Review the totals"), "kind": .string("review"),
            ])]),
        ]
        let reportResult = await caller.call(report, arguments: reportBody)
        let createResult = await caller.call(create, arguments: createBody)
        #expect(!reportResult.isError && !createResult.isError)
        let sent = await fake.requests
        #expect(sent == [
            ToolRequest(operation: .reportModel, body: reportBody, key: try #require(reportResult.key)),
            ToolRequest(operation: .createTask, body: createBody, key: try #require(createResult.key)),
        ])
    }

    @Test func getNextDefaultsToTwentySecondsAndRejectsInvalidWaits() async throws {
        let fake = RecordingTransport()
        let caller = ToolCaller(transport: fake.send)
        let next = try #require(catalog.tool(named: "get_next"))
        _ = await caller.call(next, arguments: [:])
        _ = await caller.call(next, arguments: ["wait": .number(0)])
        _ = await caller.call(next, arguments: ["wait": .number(30)])
        for value: JSONValue in [.number(-1), .number(31), .number(1.5), .string("20"), .null] {
            let reply = await caller.call(next, arguments: ["wait": value])
            #expect(reply.isError)
        }
        #expect(await fake.requests.map(\.wait) == [20, 0, 30])
    }

    @Test func rejectsMissingAndNonUUIDPathArgumentsAndAnInvalidKey() async throws {
        let fake = RecordingTransport()
        let caller = ToolCaller(transport: fake.send)
        let release = try #require(catalog.tool(named: "release_task"))
        for args: [String: JSONValue] in [
            [:], ["id": .string("../owner")],
            ["id": .string(taskID), "idempotency_key": .string("spaces in key")]
        ] {
            let reply = await caller.call(release, arguments: args)
            #expect(reply.isError)
        }
        #expect(await fake.requests.isEmpty)
    }

    @Test func propagatesRefusalWithItsCodeAndKey() async throws {
        let fake = RecordingTransport([refused(.notHolder)])
        let caller = ToolCaller(transport: fake.send)
        let tool = try #require(catalog.tool(named: "release_task"))
        let reply = await caller.call(tool, arguments: ["id": .string(taskID)])
        #expect(reply.isError)
        #expect(reply.key != nil)
        #expect(reply.response?.status == 409)
        #expect(reply.response?.body["refusal"]?["code"] == .string("not_holder"))
    }

    @Test(arguments: [false, true])
    func criterionPassInsertsAStartOnlyWhenItHasNotSeenOne(explicitStart: Bool) async throws {
        let fake = RecordingTransport()
        let caller = ToolCaller(transport: fake.send)
        let path: [String: JSONValue] = ["id": .string(taskID), "cid": .string(criterionID)]
        if explicitStart {
            let start = try #require(catalog.tool(named: "start_criterion"))
            let answer = await caller.call(start, arguments: path)
            #expect(!answer.isError)
        }
        let pass = try #require(catalog.tool(named: "pass_criterion"))
        var args = path
        args["evidence"] = .object(["note": .string("fixture evidence")])
        let answer = await caller.call(pass, arguments: args)
        let requests = await fake.requests
        try #require(requests.count == 2)
        #expect(requests.map(\.operation) == [.startCriterion, .passCriterion])
        #expect(requests[0].path == requests[1].path)
        #expect(requests[0].key != requests[1].key)
        #expect(requests[1].key == answer.key)
        #expect(!answer.isError)
    }

    @Test func retryingAPassFromAnEarlierSessionCannotReopenTheCriterion() async throws {
        let key = "fixture-earlier-pass"
        let fake = RecordingTransport([ToolResponse(status: 200, body: .object([
            "key": .string(key), "command": .string("pass_criterion"), "outcome": .string("completed")
        ])), completed()])
        let caller = ToolCaller(transport: fake.send)
        let pass = try #require(catalog.tool(named: "pass_criterion"))
        let answer = await caller.call(pass, arguments: [
            "id": .string(taskID), "cid": .string(criterionID), "idempotency_key": .string(key),
            "evidence": .object(["note": .string("fixture evidence")])
        ])
        #expect(!answer.isError)
        #expect(answer.key?.value == key)
        let requests = await fake.requests
        #expect(requests.map(\.operation) == [.getCommand, .passCriterion])
        #expect(requests.first?.path == ["key": key])
    }

    @Test func newExplicitPassKeyGetsAStartThenRetryReusesThePassKey() async throws {
        let fake = RecordingTransport([ToolResponse(status: 404, body: .null), completed(), completed(), completed()])
        let caller = ToolCaller(transport: fake.send)
        let pass = try #require(catalog.tool(named: "pass_criterion"))
        let key = "fixture-new-pass"
        let arguments: [String: JSONValue] = [
            "id": .string(taskID), "cid": .string(criterionID), "idempotency_key": .string(key),
            "evidence": .object(["note": .string("fixture evidence")])
        ]
        let first = await caller.call(pass, arguments: arguments)
        let replay = await caller.call(pass, arguments: arguments)
        #expect(!first.isError && !replay.isError)
        let requests = await fake.requests
        #expect(requests.map(\.operation) == [.getCommand, .startCriterion, .passCriterion, .passCriterion])
        #expect(requests.suffix(2).allSatisfy { $0.key?.value == key })
    }

    @Test func aPolledRefusalRetainsItsHTTPStatusAndReportsAToolError() async throws {
        let apiRefusal = refused(.notHolder)
        let fake = RecordingTransport([ToolResponse(status: 200, body: apiRefusal.body)])
        let caller = ToolCaller(transport: fake.send)
        let poll = try #require(catalog.tool(named: "get_command"))
        let reply = await caller.call(poll, arguments: ["key": .string("fixture-command")])
        #expect(reply.isError)
        #expect(reply.response?.status == 200)
        #expect(reply.response?.body["refusal"]?["code"] == .string("not_holder"))
    }

    @Test(arguments: [false, true])
    func replayingAnOldClaimCannotRedirectTheHeartbeat(crossSession: Bool) async throws {
        let priorClaim = claim(taskID)
        let answers = crossSession
            ? [claim(otherTaskID), priorClaim, priorClaim, completed()]
            : [priorClaim, completed(), claim(otherTaskID), priorClaim, completed()]
        let fake = RecordingTransport(answers)
        let caller = ToolCaller(transport: fake.send)
        let claim = try #require(catalog.tool(named: "claim_next_task"))
        let release = try #require(catalog.tool(named: "release_task"))
        let oldKey: String
        if crossSession {
            oldKey = "fixture-old-key"
        } else {
            let first = await caller.call(claim, arguments: [:])
            oldKey = try #require(first.key?.value)
            _ = await caller.call(release, arguments: ["id": .string(taskID)])
        }
        _ = await caller.call(claim, arguments: [:])
        let replay = await caller.call(claim, arguments: ["idempotency_key": .string(oldKey)])
        #expect(!replay.isError)
        #expect(replay.response?.body["result"]?["task"]?["id"] == .string(taskID))
        await caller.heartbeat()
        let last = await fake.requests.last
        #expect(last?.operation == .heartbeatTask)
        #expect(last?.path == ["id": otherTaskID])
    }

    @Test(arguments: [false, true])
    func retryingAPendingClaimFromAnEarlierSessionLearnsItsLease(settledBeforeRetry: Bool) async throws {
        let pendingBody = JSONValue.object([
            "command": .string("claim"), "outcome": .string("pending"), "result": .null,
        ])
        let lookup = ToolResponse(status: 200, body: pendingBody)
        let completedClaim = claim(taskID)
        let fake = RecordingTransport(settledBeforeRetry ? [lookup, completedClaim] : [
            lookup, ToolResponse(status: 202, body: pendingBody), completedClaim,
        ])
        let caller = ToolCaller(transport: fake.send)
        let claimTool = try #require(catalog.tool(named: "claim_next_task"))
        let poll = try #require(catalog.tool(named: "get_command"))
        let key = "fixture-earlier-pending-claim"

        let retry = await caller.call(claimTool, arguments: ["idempotency_key": .string(key)])
        #expect(retry.response?.status == (settledBeforeRetry ? 200 : 202))
        if !settledBeforeRetry {
            let settled = await caller.call(poll, arguments: ["key": .string(key)])
            #expect(settled.response?.body["outcome"] == .string("completed"))
        }

        await caller.heartbeat()
        let requests = await fake.requests
        let expected: [ContractOperation] = settledBeforeRetry
            ? [.getCommand, .claimNextTask, .heartbeatTask]
            : [.getCommand, .claimNextTask, .getCommand, .heartbeatTask]
        #expect(requests.map(\.operation) == expected)
        #expect(requests.last?.path == ["id": taskID])
    }

    @Test func replayingAReleaseCannotClearANewLeaseOnTheSameTask() async throws {
        let fake = RecordingTransport([claim(taskID), completed(), claim(taskID), completed(), completed()])
        let caller = ToolCaller(transport: fake.send)
        let claim = try #require(catalog.tool(named: "claim_next_task"))
        let release = try #require(catalog.tool(named: "release_task"))
        _ = await caller.call(claim, arguments: [:])
        let first = await caller.call(release, arguments: ["id": .string(taskID)])
        let key = try #require(first.key)
        _ = await caller.call(claim, arguments: [:])
        let repeated = await caller.call(release, arguments: ["id": .string(taskID),
                                                              "idempotency_key": .string(key.value)])
        #expect(!repeated.isError)
        await caller.heartbeat()
        #expect(await fake.requests.last?.operation == .heartbeatTask)
    }

    @Test func uncertainAutomaticStartKeepsItsOwnKeyAndReturnsThePassKey() async throws {
        let fake = UncertainStartTransport()
        let caller = ToolCaller(transport: fake.send)
        let pass = try #require(catalog.tool(named: "pass_criterion"))
        var arguments: [String: JSONValue] = [
            "id": .string(taskID), "cid": .string(criterionID),
            "evidence": .object(["note": .string("fixture evidence")])
        ]
        let first = await caller.call(pass, arguments: arguments)
        let passKey = try #require(first.key)
        #expect(first.isError)
        arguments["idempotency_key"] = .string(passKey.value)
        let retry = await caller.call(pass, arguments: arguments)
        #expect(!retry.isError)
        #expect(retry.key == passKey)
        let requests = await fake.requests
        try #require(requests.map(\.operation) == [.startCriterion, .startCriterion, .passCriterion])
        #expect(requests[0].key == requests[1].key)
        #expect(requests[0].key != passKey)
        #expect(requests[2].key == passKey)
    }

    @Test func refusedCriterionStartPreventsThePass() async throws {
        let fake = RecordingTransport([refused(.notHolder)])
        let caller = ToolCaller(transport: fake.send)
        let pass = try #require(catalog.tool(named: "pass_criterion"))
        let result = await caller.call(pass, arguments: [
            "id": .string(taskID), "cid": .string(criterionID), "evidence": .object(["note": .string("fixture")])
        ])
        #expect(result.isError)
        #expect(result.response?.status == 409)
        #expect(await fake.requests.map(\.operation) == [.startCriterion])
    }

    @Test(arguments: [false, true])
    func actionDoneRequiresAnAcceptedStartOrOneSeenInTheLastBriefing(briefingFirst: Bool) async throws {
        let fake = RecordingTransport(briefingFirst ? [briefing(actionState: "started")] : [])
        let caller = ToolCaller(transport: fake.send)
        let done = try #require(catalog.tool(named: "report_action_done"))
        let args: [String: JSONValue] = ["id": .string(taskID), "aid": .string(actionID)]
        let premature = await caller.call(done, arguments: args)
        #expect(premature.isError)
        #expect(await fake.requests.isEmpty)

        if briefingFirst {
            let tool = try #require(catalog.tool(named: "get_task_briefing"))
            let snapshot = await caller.call(tool, arguments: ["id": .string(taskID)])
            #expect(!snapshot.isError)
        } else {
            let tool = try #require(catalog.tool(named: "start_action"))
            let start = await caller.call(tool, arguments: args)
            #expect(!start.isError)
        }
        let accepted = await caller.call(done, arguments: args)
        #expect(!accepted.isError)
        #expect(await fake.requests.map(\.operation) ==
                [briefingFirst ? .getTaskBriefing : .startAction, .reportActionDone])
    }

    @Test func aRefusedActionStartDoesNotUnlockReportingDone() async throws {
        let fake = RecordingTransport([refused(.invalidState)])
        let caller = ToolCaller(transport: fake.send)
        let start = try #require(catalog.tool(named: "start_action"))
        let done = try #require(catalog.tool(named: "report_action_done"))
        let args: [String: JSONValue] = ["id": .string(taskID), "aid": .string(actionID)]
        let refusedStart = await caller.call(start, arguments: args)
        let refusedDone = await caller.call(done, arguments: args)
        #expect(refusedStart.isError && refusedDone.isError)
        #expect(await fake.requests.map(\.operation) == [.startAction])
    }
}


private actor UncertainStartTransport {
    private(set) var requests: [ToolRequest] = []

    func send(_ request: ToolRequest) async throws -> ToolResponse {
        requests.append(request)
        if requests.count == 1 { throw URLError(.timedOut) }
        if request.operation == .getCommand { return ToolResponse(status: 404, body: .null) }
        return completed()
    }
}
