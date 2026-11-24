import Foundation
import LeverageKit
import LeverageTestSupport
import Testing

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@Suite(.enabled(if: questionsApprovalsEnabled), .timeLimit(.minutes(Patience.minutes(8))))
struct MCPEndToEndTests {
    @Test func testBuilderThroughMCPReachesDone() async throws {
        try await withQuestionsApprovalsWorld("mcp") { world in
            let builder = try await world.manualBuilder(connection: .mcp)
            let task = try await world.addTask(title: "Builder using MCP").task
            try await world.waitFor("task.ready", task: task) { $0.taskID == task && $0.type == .taskReady }

            let session = try MCPSession(token: builder.token)
            defer { session.cleanUp() }
            let keys = try runBuilder(session, task: task, world: world)

            try session.client.closeInput()
            #expect(try session.waitForExit() == 0)
            let protocolEndedAtEOF = try session.client.receive() == nil
            #expect(protocolEndedAtEOF)
            let stderr = try session.stderr.fileHandleForReading.readToEnd() ?? Data()
            let tokenAbsent = stderr.range(of: Data(builder.token.utf8)) == nil
            try #require(tokenAbsent, "the MCP process kept its token out of stderr")
            try stderr.write(to: world.folder.logs.appendingPathComponent("mcp.log"))

            try await world.waitForDone(task)
            let events = try await world.wholeLog().filter { $0.taskID == task }
            let orchestrator = world.orchestrator
            let reviewer = world.reviewer
            let claimed = try questionsApprovalsOrder(events, [
                .type(.taskClaimed) { $0.actorID == builder.seat && $0.payload["credential_id"] == .null },
                .type(.taskBriefingAcknowledged), .type(.questionAsked),
                .type(.questionAnswered) { $0.actorID == orchestrator && $0.string("basis") == "record" },
                .type(.costReported) { $0.actorID == builder.seat },
                .type(.criterionStarted), .type(.criterionPassed), .type(.taskSubmitted),
                .type(.reviewStarted) { $0.actorID == reviewer },
                .type(.reviewPassed), .type(.taskDone),
            ])
            let announced = try #require(claimed.first { $0.type == .criterionStarted })
            let syntheticKey = try #require(announced.commandID.flatMap(IdempotencyKey.init))
            #expect(!keys.values.contains(syntheticKey.value), "the implicit start uses its own command key")
            let seatEvents = events.filter { $0.actorID == builder.seat }
            let permittedKeys = Set(keys.values).union([syntheticKey.value])
            #expect(seatEvents.allSatisfy { $0.commandID.map(permittedKeys.contains) == true })
            for (eventType, key) in keys {
                #expect(seatEvents.contains { $0.type == eventType && $0.commandID == key })
            }
        }
    }

    private func runBuilder(
        _ session: MCPSession, task: UUID, world: QuestionsApprovalsWorld
    ) throws -> [EventType: String] {
        let client = session.client
        let initialized = try client.initialize()
        let revision = (initialized["result"] as? [String: Any])?["protocolVersion"] as? String
        #expect(revision == "2025-06-18")
        try client.send(["jsonrpc": "2.0", "id": "catalog", "method": "tools/list"])
        let catalog = try #require(try client.receive() as? [String: Any])
        #expect(catalog["jsonrpc"] as? String == "2.0" && catalog["id"] as? String == "catalog")
        let tools = ((catalog["result"] as? [String: Any])?["tools"] as? [[String: Any]]) ?? []
        let names = tools.compactMap { $0["name"] as? String }
        let expected = AgentTools.all.filter { $0.roles.contains(.builder) }.map(\.id)
        #expect(names.sorted() == expected.sorted())

        let join = try session.call("get_join")
        #expect(join.body["connection"] as? String == "mcp")
        #expect(join.body["role"] as? String == "builder")

        let id = task.contractString
        let next = try session.call("get_next", ["wait": 0])
        #expect(next.body["kind"] as? String == "task")
        let claim = try session.call("claim_next_task")
        let summary = (claim.body["result"] as? [String: Any])?["task"] as? [String: Any]
        #expect(summary?["id"] as? String == id)

        let briefing = try session.call("get_task_briefing", ["id": id])
            .body["briefing"] as? [String: Any]
        let hash = try #require(briefing?["hash"] as? String)
        let ack = try session.call("acknowledge_task_briefing", ["id": id, "briefing_hash": hash])

        let assumption = "Proceed using \(world.marker("assumption"))."
        let asked = try session.call("ask_question", [
            "id": id, "text": "How should I handle \(world.marker("question"))?", "assumption": assumption,
            "blocking": false,
        ])
        let askedResult = asked.body["result"] as? [String: Any]
        let qid = try #require(askedResult?["question_id"] as? String)
        let deadline = ContinuousClock.now + Patience.scaled(.seconds(120))
        while true {
            let offered = try session.call("get_next", ["wait": 10])
            if offered.body["kind"] as? String == "answer" {
                #expect(offered.body["id"] as? String == qid)
                break
            }
            guard ContinuousClock.now < deadline else { throw EndToEndFailure("MCP builder received no answer offer") }
        }
        let question = try session.call("get_question", ["id": id, "qid": qid])
        let matchesAnswer = question.body["answer"] as? String == assumption
        #expect(matchesAnswer)
        #expect(question.body["basis"] as? String == "record")

        let cost = try session.call("report_cost", ["id": id, "tokens": 7, "spend": 0])
        // The owner chooses the criterion in the contract. The test uses
        // its ID from the briefing carried by the claim.
        let claimBriefing = (claim.body["result"] as? [String: Any])?["briefing"] as? [String: Any]
        let contract = claimBriefing?["contract"] as? [String: Any]
        let criteria = contract?["criteria"] as? [[String: Any]]
        let criterion = try #require(criteria?.first { $0["kind"] as? String == "build" }?["id"] as? String)
        let passed = try session.call("pass_criterion", [
            "id": id, "cid": criterion, "evidence": ["kind": "note", "value": "The fixture's one build criterion."],
        ])
        let submitted = try session.call("submit_task", [
            "id": id, "handoff_note": "The test's work is ready.", "work_reference": world.work.path,
        ])
        let refused = try session.call("get_question", ["id": id, "qid": qid], expecting: 409)
        #expect(refused.body["code"] as? String == "not_holder")
        #expect(refused.key == nil)

        let responses: [(EventType, MCPAnswer)] = [
            (.taskClaimed, claim), (.taskBriefingAcknowledged, ack), (.questionAsked, asked),
            (.costReported, cost), (.criterionPassed, passed), (.taskSubmitted, submitted),
        ]
        return try Dictionary(uniqueKeysWithValues: responses.map { (type, answer) in
            (type, try #require(answer.key.flatMap(IdempotencyKey.init)).value)
        })
    }
}

private struct MCPAnswer {
    let body: [String: Any]
    let key: String?
}

private final class MCPSession {
    let process = Process()
    let input = Pipe()
    let output = Pipe()
    let stderr = Pipe()
    let client: ScriptedMCPClient
    private let exited = DispatchSemaphore(value: 0)

    init(token: String) throws {
        client = ScriptedMCPClient(
            input: input.fileHandleForWriting, output: output.fileHandleForReading, timeout: Patience.scaled(.seconds(30)))
        process.executableURL = try EndToEnd.program("LeverageMCP")
        process.environment = [
            EnvironmentKeys.apiURL: EndToEnd.apiURL.absoluteString,
            EnvironmentKeys.seatToken: token,
            EnvironmentKeys.seatRole: "builder",
        ]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = stderr
        let exited = self.exited
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
    }

    func call(_ name: String, _ arguments: [String: Any] = [:], expecting status: Int = 200) throws -> MCPAnswer {
        let result = try client.call(name: name, arguments: arguments)
        guard let content = result["content"] as? [[String: Any]], content.count == 1,
              content.first?["type"] as? String == "text", let text = content.first?["text"] as? String,
              let wrapper = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let body = wrapper["body"] as? [String: Any] else {
            throw EndToEndFailure("MCP \(name) returned an invalid envelope")
        }
        guard wrapper["status"] as? Int == status,
              (result["isError"] as? Bool ?? false) == (status >= 400) else {
            let received = wrapper["status"] as? Int
            throw EndToEndFailure("MCP \(name) expected HTTP \(status), got \(received.map(String.init) ?? "none")")
        }
        return MCPAnswer(body: body, key: wrapper["key"] as? String)
    }

    func waitForExit() throws -> Int32 {
        guard exited.wait(timeout: .now() + Patience.seconds(30)) == .success else {
            throw EndToEndFailure("LeverageMCP did not exit after its input closed")
        }
        return process.terminationStatus
    }

    func cleanUp() {
        try? client.closeInput()
        guard process.isRunning else { return }
        _ = kill(process.processIdentifier, SIGKILL)
        if exited.wait(timeout: .now() + Patience.seconds(30)) != .success {
            Issue.record("The LeverageMCP child did not exit")
        }
    }
}
