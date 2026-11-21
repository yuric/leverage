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
        #expect(requests == Array(repeating: ToolRequest(operation: .askQuestion, path: ["id": taskID],
                                                          body: body, key: key), count: 2))
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
