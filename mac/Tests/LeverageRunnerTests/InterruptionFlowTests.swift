import Foundation
import LeverageKit
import LeverageTestSupport
import Testing

@testable import LeverageRunner

/// What an interruption does to a builder's and a reviewer's flow (HD-5,
/// HD-6, HD-7): a limit or a sign-out ends the run with code 5 and one
/// report, releases nothing and stops the heartbeat; anything else is
/// milestone 2's failure.
@Suite("Interruption in the flows", .timeLimit(.minutes(Patience.minutes(1))))
struct InterruptionFlowTests {
    let taskID = UUID()
    let firstID = UUID()
    let secondID = UUID()
    let reviewID = UUID()

    func criteria() -> [Criterion] {
        [
            Fixture.criterion(taskID, 1, "The copy names this year's prices.", id: firstID),
            Fixture.criterion(taskID, 2, "The layout matches the rest of the site.", id: secondID),
        ]
    }

    func interruption(credential: Bool = true, status: StatusAnswers = StatusAnswers(.signedIn),
                      waits: [Duration] = InterruptionTests.noWaits) -> Interruption {
        Interruption(provider: .claude, hasCredential: credential, waits: waits, signInStatus: status.check)
    }

    func builder(
        _ harness: Harness, driver: any ToolDriver, interruption: Interruption,
        timing: RunnerTiming = .fast(heartbeatEvery: .milliseconds(10))
    ) -> RunnerLoop {
        let loop = harness.loop(.builder, driver: driver, timing: timing, interruption: interruption)
        let claim = Fixture.claim(taskID, criteria: criteria(), workReference: harness.existingWork.path)
        harness.api.script {
            $0.claimNextTask = { _ in .completed(claim, key: "k", command: .claim) }
            $0.acknowledgeTaskBriefing = { _, _, _ in Fixture.done(.acknowledgeBriefing) }
            $0.startCriterion = { _, _, _ in Fixture.done(.startCriterion) }
            $0.passCriterion = { _, _, _, _ in Fixture.done(.passCriterion) }
            $0.submitTask = { _, _, _ in Fixture.done(.submit) }
            $0.releaseTask = { _, _, _ in Fixture.done(.release) }
            $0.heartbeatTask = { _, _ in Fixture.beat() }
        }
        return loop
    }

    /// The first build answers with `first`, every later one with evidence.
    func driver(first: ScriptedDriver.Step) -> ScriptedDriver {
        let runs = Counter()
        return ScriptedDriver { _, purpose in
            if purpose == .build, runs.increment() == 1 { return first }
            return .answer("Done.\nLEVERAGE-EVIDENCE: proof.txt in the work folder", tokens: 10)
        }
    }

    func failedRun(_ file: String) throws -> ScriptedDriver.Step {
        .failRun(.exited(1), try ReplyFile("claude", file).record)
    }

    @Test("a limit reply ends the run with code 5 and its report; nothing is released or passed")
    func limitEndsRun() async throws {
        let harness = try Harness()
        let loop = builder(harness, driver: driver(first: try failedRun("run-limit-five-hour.json")),
                           interruption: interruption())
        harness.next([NextItem(kind: .task)], then: loop)

        #expect(await runToEnd(loop) == 5)
        let report = try #require(loop.endReport)
        #expect(report.kind == .limit)
        #expect(report.window == .fiveHour)
        #expect(report.resetAt == ReplyFile.resetAt)
        #expect(report.taskID == taskID)
        #expect(report.reviewID == nil)
        #expect(harness.calls(.releaseTask).isEmpty)
        #expect(harness.calls(.passCriterion).isEmpty)
        #expect(harness.calls(.submitTask).isEmpty)
        #expect(harness.calls(.getNext).count == 1, "the loop ends: no next item is asked for")
    }

    @Test("after the account stops no heartbeat is sent")
    func noHeartbeatAfter() async throws {
        let harness = try Harness()
        let loop = builder(harness, driver: driver(first: try failedRun("run-signed-out.json")),
                           interruption: interruption(), timing: .fast(heartbeatEvery: .milliseconds(5)))
        harness.next([NextItem(kind: .task)], then: loop)

        #expect(await runToEnd(loop) == 5)
        let beats = harness.calls(.heartbeatTask).count
        try await Task.sleep(for: .milliseconds(80))
        #expect(harness.calls(.heartbeatTask).count == beats)
    }

    @Test("a stop that comes after the account stopped releases nothing")
    func stopAfterwards() async throws {
        let harness = try Harness()
        let loop = builder(harness, driver: driver(first: try failedRun("run-signed-out.json")),
                           interruption: interruption())
        harness.next([NextItem(kind: .task)], then: loop)
        #expect(await runToEnd(loop) == 5)
        loop.stop()
        #expect(harness.calls(.releaseTask).isEmpty)
    }

    @Test("a failed run with a signed-out status ends the run as a sign-out")
    func statusSignedOut() async throws {
        let harness = try Harness()
        let status = StatusAnswers(.signedOut)
        let loop = builder(harness, driver: driver(first: try failedRun("run-failed.json")),
                           interruption: interruption(status: status))
        harness.next([NextItem(kind: .task)], then: loop)

        #expect(await runToEnd(loop) == 5)
        #expect(loop.endReport?.kind == .signedOut)
        #expect(loop.endReport?.window == nil)
        #expect(status.count == 1)
        #expect(harness.calls(.releaseTask).isEmpty)
    }

    @Test("a failed run with a signed-in status is released as before (CL-22)")
    func statusSignedIn() async throws {
        let harness = try Harness()
        let status = StatusAnswers(.signedIn)
        let loop = builder(harness, driver: driver(first: try failedRun("run-failed.json")),
                           interruption: interruption(status: status))
        harness.next([NextItem(kind: .task)], then: loop)

        #expect(await runToEnd(loop) == 0)
        #expect(loop.endReport == nil)
        #expect(harness.calls(.releaseTask).map { $0.body?["reason"]?.stringValue } == ["unable_to_continue"])
        #expect(status.count == 1)
    }

    @Test("with no credential a limit reply is released as before")
    func noCredential() async throws {
        let harness = try Harness()
        let status = StatusAnswers(.signedOut)
        let loop = builder(harness, driver: driver(first: try failedRun("run-limit-five-hour.json")),
                           interruption: interruption(credential: false, status: status))
        harness.next([NextItem(kind: .task)], then: loop)

        #expect(await runToEnd(loop) == 0)
        #expect(loop.endReport == nil)
        #expect(harness.calls(.releaseTask).map { $0.body?["reason"]?.stringValue } == ["unable_to_continue"])
        #expect(status.count == 0)
    }

    @Test("a short rate limit is retried in place with the heartbeat running, and the work goes on")
    func rateLimitInPlace() async throws {
        let harness = try Harness()
        let rate = try ReplyFile("claude", "run-rate-limited.json").record
        let builds = Counter()
        let driver = ScriptedDriver { _, purpose in
            if purpose == .build, builds.increment() <= 3 { return .failRun(.exited(1), rate) }
            return .answer("Done.\nLEVERAGE-EVIDENCE: proof.txt in the work folder", tokens: 10)
        }
        let loop = builder(harness, driver: driver,
                           interruption: interruption(waits: [.milliseconds(40), .milliseconds(40), .milliseconds(40)]),
                           timing: .fast(heartbeatEvery: .milliseconds(5)))
        harness.next([NextItem(kind: .task)], then: loop)

        #expect(await runToEnd(loop) == 0)
        #expect(driver.runs.filter { $0.purpose == .build }.count == 5, "four runs of the first criterion (three refused), then one")
        #expect(harness.calls(.startCriterion).count == 2, "the retry announces nothing again")
        #expect(harness.calls(.passCriterion).count == 2)
        #expect(harness.calls(.releaseTask).isEmpty)
        #expect(!harness.calls(.heartbeatTask).isEmpty)
    }

    @Test("a rate limit that outlasts the retries is one failed run, released")
    func rateLimitOutlasts() async throws {
        let harness = try Harness()
        let rate = try ReplyFile("claude", "run-rate-limited.json").record
        let driver = ScriptedDriver { _, _ in .failRun(.exited(1), rate) }
        let loop = builder(harness, driver: driver, interruption: interruption())
        harness.next([NextItem(kind: .task)], then: loop)

        #expect(await runToEnd(loop) == 0)
        #expect(driver.runs.count == 4)
        #expect(harness.calls(.releaseTask).count == 1)
    }

    @Test("a reviewer's limit ends the run with code 5 naming the review; the review is not released")
    func reviewerLimit() async throws {
        let harness = try Harness()
        let record = try ReplyFile("claude", "run-limit-weekly-no-reset.json").record
        let loop = harness.loop(
            .reviewer, driver: ScriptedDriver { _, _ in .failRun(.exited(1), record) },
            timing: .fast(heartbeatEvery: .milliseconds(10)), interruption: interruption())
        let claim = Fixture.reviewClaim(
            reviewID, taskID: taskID, criteria: criteria(), workReference: harness.existingWork.path)
        harness.api.script {
            $0.claimNextReview = { _ in .completed(claim, key: "k", command: .claimReview) }
            $0.acknowledgeReviewBriefing = { _, _, _ in Fixture.done(.acknowledgeReviewBriefing) }
            $0.releaseReview = { _, _ in Fixture.done(.releaseReview) }
            $0.heartbeatReview = { _, _ in
                .completed(HeartbeatResult(leaseDueAt: Date().addingTimeInterval(3600)), key: "k",
                           command: .heartbeatReview)
            }
        }
        harness.next([NextItem(kind: .review)], then: loop)

        #expect(await runToEnd(loop) == 5)
        let report = try #require(loop.endReport)
        #expect(report.kind == .limit)
        #expect(report.window == .weekly)
        #expect(report.resetAt == nil)
        #expect(report.reviewID == reviewID)
        #expect(report.taskID == nil)
        #expect(harness.calls(.releaseReview).isEmpty)
        #expect(harness.calls(.giveVerdict).isEmpty)
    }
}

/// The runner's one line on standard output (HD-6).
@Suite("Runner end")
struct RunnerEndTests {
    let log = Log(component: "runner-end-test", write: { _ in })
    let report = RunEndReport(
        kind: .limit, window: .fiveHour, resetAt: ReplyFile.resetAt, taskID: UUID(), reviewID: nil,
        toolVersion: nil, observedAt: Date(timeIntervalSince1970: 1_899_999_000))

    @Test("code 5 writes the report as one line the helper reads back")
    func writesLine() throws {
        var written: [String] = []
        #expect(RunnerEnd.finish(code: 5, report: report, log: log) { written.append($0) } == 5)
        #expect(written.count == 1)
        let line = try #require(written.first)
        #expect(!line.dropLast().contains("\n"))
        #expect(try RunEndReport(lastLineOf: Data(line.utf8)) == report)
    }

    @Test("code 5 with no report writes nothing and is code 4")
    func noReport() {
        var written: [String] = []
        #expect(RunnerEnd.finish(code: 5, report: nil, log: log) { written.append($0) } == 4)
        #expect(written.isEmpty)
    }

    @Test("every other code writes nothing", arguments: [Int32(0), 1, 3, 4])
    func otherCodes(code: Int32) {
        var written: [String] = []
        #expect(RunnerEnd.finish(code: code, report: report, log: log) { written.append($0) } == code)
        #expect(written.isEmpty)
    }
}

/// The interruption of a real run of a stand-in tool, with the status
/// command a stand-in answers with a made-up email (PV-7): neither the
/// tool's text nor the email reaches a log line or the report line.
@Suite("Interruption against the stand-ins", .timeLimit(.minutes(Patience.minutes(2))))
struct InterruptionStandInTests {
    let setup: DriverTests.Setup
    let claude = DriverTests.cases[0]
    let lines = LockedLines()

    init() throws {
        setup = try DriverTests.Setup()
    }

    var log: Log { Log(component: "interruption-test", write: lines.add) }

    func tool() throws -> ToolConfiguration {
        try ToolConfiguration(environment: setup.environment(claude))
    }

    func scenario(_ directives: [StandInScenario.Directive]) throws {
        try setup.tools.write(scenario: StandInScenario(directives: directives))
    }

    func run(_ interruption: Interruption) async throws -> Interruption.Result {
        let driver = try setup.driver(claude)
        let work = setup.work
        return try await interruption.run(for: .task(UUID())) {
            try await driver.execute(prompt: DriverTests.buildPrompt, in: work, purpose: .build)
        }
    }

    func statusCalls() throws -> Int {
        try setup.tools.calls().filter { $0.argv.prefix(2) == ["auth", "status"] }.count
    }

    func expectQuiet(_ markers: [String], report: RunEndReport? = nil) throws {
        let reportLine = try report?.line() ?? ""
        for marker in markers + [StandIns.statusEmail] {
            #expect(!lines.all.contains { $0.contains(marker) }, "a log line holds \(marker)")
            #expect(!reportLine.contains(marker), "the report line holds \(marker)")
        }
    }

    @Test("a limit reply from the tool stops the account; no log line and no report line holds the reply")
    func limit() async throws {
        try setup.signIn(claude)
        try scenario([.reply("claude/run-limit-five-hour.json", tool: "claude", account: setup.account,
                             onPrompt: 1, resetInSeconds: 3600)])
        let marker = try ReplyFile("claude", "run-limit-five-hour.json").marker
        let result = try await run(.runner(tool: try tool(), credentialID: UUID(), log: log))
        guard case .accountStopped(let report) = result else {
            Issue.record("expected the account to stop, got \(result)")
            return
        }
        #expect(report.kind == .limit && report.window == .fiveHour)
        let reset = try #require(report.resetAt)
        #expect(abs(reset.timeIntervalSinceNow - 3600) < 120)
        #expect(try statusCalls() == 0)
        #expect(!lines.all.isEmpty, "the outcome's kind is logged")
        try expectQuiet([marker], report: report)
    }

    @Test("a failed run on a signed-in account asks the status, goes on as before, and logs no email")
    func failedSignedIn() async throws {
        try setup.signIn(claude)
        try scenario([.reply("claude/run-failed.json", tool: "claude", account: setup.account, onPrompt: 1)])
        let marker = try ReplyFile("claude", "run-failed.json").marker
        let result = try await run(.runner(tool: try tool(), credentialID: UUID(), log: log))
        #expect(result == .failed(.exited(1)))
        #expect(try statusCalls() == 1)
        try expectQuiet([marker])
    }

    @Test("a failed run whose status command says signed out is a sign-out, and logs nothing it printed")
    func failedSignedOut() async throws {
        let reply = try ReplyFile("claude", "run-failed.json")
        let interruption = Interruption.runner(tool: try tool(), credentialID: UUID(), log: log)
        #expect(await interruption.decide(after: reply.record, at: Date()) == .accountStopped(.signedOut))
        #expect(try statusCalls() == 1)
        try expectQuiet([reply.marker, try ReplyFile("claude", "status-signed-out.json").marker])
    }

    @Test("a signed-out run of the stand-in stops the account without asking the status")
    func signedOutRun() async throws {
        let result = try await run(.runner(tool: try tool(), credentialID: UUID(), log: log))
        guard case .accountStopped(let report) = result else {
            Issue.record("expected the account to stop, got \(result)")
            return
        }
        #expect(report.kind == .signedOut)
        #expect(try statusCalls() == 0)
        try expectQuiet([try ReplyFile("claude", "run-signed-out.json").marker], report: report)
    }

    @Test("with no credential the stand-in's limit is a failure and the status is never run")
    func noCredential() async throws {
        try setup.signIn(claude)
        try scenario([.reply("claude/run-limit-five-hour.json", tool: "claude", account: setup.account,
                             onPrompt: 1, resetInSeconds: 3600)])
        let result = try await run(.runner(tool: try tool(), credentialID: nil, log: log))
        #expect(result == .failed(.exited(1)))
        #expect(try statusCalls() == 0)
    }
}
