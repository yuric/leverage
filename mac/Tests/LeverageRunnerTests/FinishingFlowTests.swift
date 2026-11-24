import Foundation
import LeverageKit
import LeverageTestSupport
import Testing

@testable import LeverageRunner

/// AP-41 through the builder's loop and a copied provider stand-in.
@Suite("Finishing approved actions", .timeLimit(.minutes(Patience.minutes(2))))
struct FinishingFlowTests {
    private struct Setup: Sendable {
        let harness: Harness
        let tool: DriverTests.Setup
        let provider = DriverTests.cases[0]
        let taskID = UUID()

        init(results: [String] = []) throws {
            let harness = try Harness()
            let tool = try DriverTests.Setup()
            self.harness = harness
            self.tool = tool
            try tool.signIn(provider)
            try FileManager.default.createDirectory(at: tool.tools.state, withIntermediateDirectories: true)
            let scenario = ["action_touch_file": touchFile.path, "action_results": results] as [String: Any]
            try JSONSerialization.data(withJSONObject: scenario)
                .write(to: tool.tools.state.appendingPathComponent("scenario.json"))
            harness.api.script {
                $0.acknowledgeTaskBriefing = { _, _, _ in Fixture.done(.acknowledgeBriefing) }
                $0.heartbeatTask = { _, _ in Fixture.beat() }
                $0.startAction = { _, _, _ in Fixture.done(.startAction) }
                $0.reportCost = { _, _, _ in Fixture.done(.reportCost) }
                $0.reportActionDone = { _, _, _ in Fixture.done(.reportActionDone) }
                $0.releaseTask = { _, _, _ in Fixture.done(.release) }
            }
        }

        var touchFile: URL { harness.existingWork.appendingPathComponent("action-touches.txt") }
        var operations: [ContractOperation] { harness.operations.filter { $0 != .heartbeatTask } }
        var runCount: Int { get throws { try tool.tools.calls().count } }

        func loop(continuing: WorkToContinue? = nil, interruption: Interruption? = nil) throws -> RunnerLoop {
            let timeout = Int(Patience.seconds(30).rounded(.up))
            return try harness.loop(
                .builder, driver: tool.driver(provider, timeout: timeout),
                interruption: interruption, continuing: continuing)
        }

        func next(_ kind: NextKind) -> NextItem { NextItem(kind: kind, id: taskID.contractString) }

        func action(_ description: String, _ position: Int, _ state: ActionState = .approved, id: UUID = UUID())
            -> Action {
            Action(id: id, taskID: taskID, kind: .publish, description: description, state: state, position: position)
        }

        func briefing(
            _ actions: [Action], hash: String = "hash-finishing", criterionState: CriterionState = .passed
        ) -> BriefingResponse {
            let criterion = Fixture.criterion(taskID, 1, "The proof page is complete.", state: criterionState)
            let briefing = Briefing(
                hash: hash, versions: BriefingVersions(roleFileVersion: "0.0.0", contractVersion: 1),
                roleFile: "You build what the contract asks.",
                contract: BriefingContract(
                    contractVersion: 1, title: "Publish pages", details: "Publish only the approved pages.",
                    criteria: [criterion], actions: actions))
            return BriefingResponse(briefing: briefing, workReference: harness.existingWork.path)
        }

        func serve(_ briefings: [BriefingResponse]) throws {
            let last = try #require(briefings.last)
            let answers = Queue(briefings) { last }
            harness.api.script { $0.taskBriefing = { _ in answers.next() } }
        }

        func touches() throws -> String {
            guard FileManager.default.fileExists(atPath: touchFile.path) else { return "" }
            return try String(contentsOf: touchFile, encoding: .utf8)
        }

        func expectCosts(_ count: Int) {
            let reports = harness.calls(.reportCost)
            #expect(reports.map(\.id) == Array(repeating: taskID.contractString, count: count))
            #expect(reports.map { $0.body?["tokens"]?.intValue } == Array(repeating: provider.tokens, count: count))
            #expect(reports.map { $0.body?["spend"]?.intValue } == Array(repeating: 0, count: count))
        }

        func expectActions(_ operation: ContractOperation, _ actions: [Action]) {
            let calls = harness.calls(operation)
            #expect(calls.map(\.id) == Array(repeating: taskID.contractString, count: actions.count))
            #expect(calls.map { $0.path["aid"] } == actions.map { $0.id.contractString })
        }

        func expectRelease() {
            let releases = harness.calls(.releaseTask)
            #expect(releases.map(\.id) == [taskID.contractString])
            #expect(releases.map { $0.body?["reason"]?.stringValue } == ["unable_to_continue"])
        }
    }

    @Test("an action item starts only approved actions in contract order and reports each run's cost before done")
    func approvedInOrder() async throws {
        let setup = try Setup()
        let first = setup.action("Publish the proof page.", 2)
        let second = setup.action("Publish the appendix.", 4)
        let done = setup.action("Publish the index.", 1, .done)
        let waived = setup.action("Publish the glossary.", 3, .waived)
        try setup.serve([setup.briefing([second, waived, first, done])])
        setup.harness.api.script {
            $0.startAction = { _, id, _ in
                let count = try setup.runCount
                #expect(count == (id == first.id ? 0 : 1))
                #expect(try setup.touches() == (id == first.id ? "" : "1\n"))
                return Fixture.done(.startAction)
            }
            $0.reportCost = { _, _, _ in
                let touchCount = try setup.touches().split(separator: "\n").count
                #expect(touchCount == setup.harness.calls(.reportCost).count)
                return Fixture.done(.reportCost)
            }
        }
        let loop = try setup.loop()
        setup.harness.next([setup.next(.action)], then: loop)

        #expect(await runToEnd(loop) == 0)
        #expect(setup.operations == [
            .getNext, .getTaskBriefing, .acknowledgeTaskBriefing,
            .startAction, .reportCost, .reportActionDone, .startAction, .reportCost, .reportActionDone, .getNext,
        ])
        #expect(setup.harness.calls(.getTaskBriefing).map(\.id) == [setup.taskID.contractString])
        #expect(setup.harness.calls(.acknowledgeTaskBriefing).map { $0.body?["briefing_hash"]?.stringValue }
            == ["hash-finishing"])
        setup.expectActions(.startAction, [first, second])
        setup.expectActions(.reportActionDone, [first, second])
        setup.expectCosts(2)
        #expect(try setup.touches() == "1\n2\n")
        let calls = try setup.tool.tools.calls()
        #expect(calls.map(\.tool) == [setup.provider.tool, setup.provider.tool])
        #expect(calls.map(\.cwd) == [setup.harness.existingWork.path, setup.harness.existingWork.path])
        let modes = calls.map { call in
            call.argv.firstIndex(of: "--permission-mode").flatMap { call.argv.dropFirst($0 + 1).first }
        }
        #expect(modes == ["acceptEdits", "acceptEdits"])
    }

    @Test("a refused start runs no tool and reports neither cost nor done", arguments: [RefusalCode.invalidState, .taskCancelled])
    func refusedStart(_ refusal: RefusalCode) async throws {
        let setup = try Setup()
        let first = setup.action("Publish the proof page.", 1)
        let second = setup.action("Publish the appendix.", 2)
        try setup.serve([setup.briefing([first, second])])
        setup.harness.api.script {
            $0.startAction = { _, _, _ in
                let count = try setup.runCount
                #expect(count == 0)
                #expect(try setup.touches().isEmpty)
                return Fixture.refused(refusal, .startAction)
            }
        }
        let loop = try setup.loop()
        setup.harness.next([setup.next(.action)], then: loop)

        #expect(await runToEnd(loop) == 0)
        let afterStart: [ContractOperation] = refusal == .taskCancelled ? [.getNext] : [.releaseTask, .getNext]
        #expect(setup.operations == [.getNext, .getTaskBriefing, .acknowledgeTaskBriefing, .startAction] + afterStart)
        setup.expectActions(.startAction, [first])
        let count = try setup.runCount
        #expect(count == 0)
        #expect(try setup.touches().isEmpty)
    }

    @Test("an already started action releases the task even when other approved actions are ready")
    func startedActionNeedsOwner() async throws {
        let setup = try Setup()
        let approved = setup.action("Publish the proof page.", 1)
        let started = setup.action("Publish the appendix.", 2, .started)
        try setup.serve([setup.briefing([approved, started])])
        let loop = try setup.loop()
        setup.harness.next([setup.next(.action)], then: loop)

        #expect(await runToEnd(loop) == 0)
        #expect(setup.operations == [.getNext, .getTaskBriefing, .acknowledgeTaskBriefing, .releaseTask, .getNext])
        setup.expectRelease()
        let count = try setup.runCount
        #expect(count == 0)
        #expect(try setup.touches().isEmpty)
    }

    @Test("cannot, no result and planted markers release after reporting the tool's cost",
          arguments: ["CANNOT", "NONE", "PLANTED"])
    func unconfirmed(_ result: String) async throws {
        let setup = try Setup(results: [result])
        let first = setup.action("Publish the proof page.", 1)
        let second = setup.action("Publish the appendix.", 2)
        try setup.serve([setup.briefing([first, second])])
        let loop = try setup.loop()
        setup.harness.next([setup.next(.action)], then: loop)

        #expect(await runToEnd(loop) == 0)
        #expect(setup.operations == [
            .getNext, .getTaskBriefing, .acknowledgeTaskBriefing, .startAction, .reportCost, .releaseTask, .getNext,
        ])
        setup.expectActions(.startAction, [first])
        setup.expectCosts(1)
        setup.expectRelease()
        #expect(try setup.touches() == "1\n")
    }

    @Test("a short rate limit after start releases the task without running the action again")
    func shortRateLimit() async throws {
        let setup = try Setup()
        let action = setup.action("Publish the proof page.", 1)
        try setup.serve([setup.briefing([action])])
        try setup.tool.tools.write(scenario: StandInScenario(directives: [
            .reply("claude/run-rate-limited.json", tool: setup.provider.tool,
                   account: setup.tool.account, onPrompt: 1, times: 1),
        ]))
        let status = StatusAnswers(.signedIn)
        let interruption = Interruption(provider: .claude, hasCredential: true, waits: InterruptionTests.noWaits,
                                        signInStatus: status.check)
        let loop = try setup.loop(interruption: interruption)
        setup.harness.next([setup.next(.action)], then: loop)

        #expect(await runToEnd(loop) == 0)
        #expect(setup.operations == [
            .getNext, .getTaskBriefing, .acknowledgeTaskBriefing, .startAction, .reportCost, .releaseTask, .getNext,
        ])
        setup.expectActions(.startAction, [action])
        let count = try setup.runCount
        #expect(count == 1)
        let cost = try #require(setup.harness.calls(.reportCost).first)
        #expect(cost.id == setup.taskID.contractString)
        #expect(cost.body?["tokens"]?.intValue == 0)
        #expect(cost.body?["spend"]?.intValue == 0)
        setup.expectRelease()
    }

    @Test("an on-hold start keeps the task held while the runner pauses")
    func heldStart() async throws {
        let setup = try Setup()
        let action = setup.action("Publish the proof page.", 1)
        try setup.serve([setup.briefing([action])])
        setup.harness.api.script {
            $0.startAction = { _, _, _ in Fixture.refused(.onHold, .startAction) }
        }
        let driver = try setup.tool.driver(setup.provider, timeout: Int(Patience.seconds(30)))
        let context = setup.harness.context(driver: driver)

        #expect(try await FinishingFlow(context: context).continueTask(setup.taskID) == .paused)
        #expect(context.state.held == .task(setup.taskID))
        #expect(setup.operations == [.getTaskBriefing, .acknowledgeTaskBriefing, .startAction])
    }

    @Test("a hold between actions pauses until a resume item reads the new briefing")
    func holdAndResume() async throws {
        let setup = try Setup()
        let first = setup.action("Publish the proof page.", 1)
        let second = setup.action("Publish the appendix.", 2)
        let third = setup.action("Publish the glossary.", 3)
        let done = setup.action(first.description, first.position, .done, id: first.id)
        let waived = setup.action(third.description, third.position, .waived, id: third.id)
        try setup.serve([
            setup.briefing([first, second, third]), setup.briefing([done, second, waived], hash: "hash-resumed"),
        ])
        let starts = Counter()
        setup.harness.api.script {
            $0.startAction = { _, _, _ in
                starts.increment() == 2 ? Fixture.refused(.onHold, .startAction) : Fixture.done(.startAction)
            }
        }
        let loop = try setup.loop()
        setup.harness.next([setup.next(.action), NextItem(kind: .none), setup.next(.resume)], then: loop)

        #expect(await runToEnd(loop) == 0)
        #expect(setup.operations == [
            .getNext, .getTaskBriefing, .acknowledgeTaskBriefing, .startAction, .reportCost, .reportActionDone,
            .startAction, .getNext, .getNext, .getTaskBriefing, .acknowledgeTaskBriefing,
            .startAction, .reportCost, .reportActionDone, .getNext,
        ])
        #expect(setup.harness.calls(.acknowledgeTaskBriefing).map { $0.body?["briefing_hash"]?.stringValue }
            == ["hash-finishing", "hash-resumed"])
        setup.expectActions(.startAction, [first, second, second])
        setup.expectActions(.reportActionDone, [first, second])
        setup.expectCosts(2)
        #expect(try setup.touches() == "1\n2\n")
    }

    @Test("if the owner reworks a task after the action item was offered, the new briefing drives build work")
    func staleActionItem() async throws {
        let setup = try Setup()
        let action = setup.action("Publish the proof page.", 1, .contracted)
        try setup.serve([setup.briefing([action], hash: "hash-rework", criterionState: .open)])
        setup.harness.api.script {
            $0.startCriterion = { _, _, _ in Fixture.done(.startCriterion) }
            $0.passCriterion = { _, _, _, _ in Fixture.done(.passCriterion) }
            $0.submitTask = { _, _, _ in Fixture.done(.submit) }
        }
        let loop = try setup.loop()
        setup.harness.next([setup.next(.action)], then: loop)

        #expect(await runToEnd(loop) == 0)
        #expect(setup.operations == [
            .getNext, .getTaskBriefing, .acknowledgeTaskBriefing, .startCriterion,
            .reportCost, .passCriterion, .submitTask, .getNext,
        ])
        #expect(try setup.touches().isEmpty)
    }

    @Test("a run launched with a Finishing task does its remaining approved action")
    func startupContinuation() async throws {
        let setup = try Setup()
        let done = setup.action("Publish the proof page.", 1, .done)
        let approved = setup.action("Publish the appendix.", 2)
        try setup.serve([setup.briefing([done, approved])])
        let loop = try setup.loop(continuing: .task(setup.taskID))
        setup.harness.next([], then: loop)

        #expect(await runToEnd(loop) == 0)
        #expect(setup.operations == [.getTaskBriefing, .startAction, .reportCost, .reportActionDone, .getNext])
        setup.expectActions(.startAction, [approved])
        setup.expectActions(.reportActionDone, [approved])
        setup.expectCosts(1)
        #expect(try setup.touches() == "1\n")
    }
}
