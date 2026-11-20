import Foundation
import LeverageKit
import LeverageTestSupport
import Testing

@testable import LeverageRunner

/// A run started with work to continue (HD-9): it reads the work's
/// briefing, goes on from the first criterion that has not passed and
/// announces it again; it acknowledges only when a call is refused
/// `briefing_not_acknowledged` or `briefing_changed`; when the work is no
/// longer the seat's it drops it and polls as usual. Nothing of the
/// previous run is used.
@Suite("Continuing work at start", .timeLimit(.minutes(Patience.minutes(1))))
struct ContinuationTests {
    let taskID = UUID()
    let firstID = UUID()
    let secondID = UUID()
    let reviewID = UUID()

    func criteria() -> [Criterion] {
        [
            Fixture.criterion(taskID, 1, "The copy names this year's prices.", state: .passed, id: firstID),
            Fixture.criterion(taskID, 2, "The layout matches the rest of the site.", state: .started, id: secondID),
        ]
    }

    func builder(
        _ harness: Harness,
        startCriterion: @escaping @Sendable (UUID) -> PlainOutcome = { _ in Fixture.done(.startCriterion) }
    ) -> RunnerLoop {
        let loop = harness.loop(.builder, driver: ScriptedDriver.agreeable(), continuing: .task(taskID))
        let briefing = BriefingResponse(
            briefing: Fixture.briefing(hash: "hash-held", criteria: criteria()),
            workReference: harness.existingWork.path)
        harness.api.script {
            $0.taskBriefing = { _ in briefing }
            $0.acknowledgeTaskBriefing = { _, _, _ in Fixture.done(.acknowledgeBriefing) }
            $0.startCriterion = { _, cid, _ in startCriterion(cid) }
            $0.passCriterion = { _, _, _, _ in Fixture.done(.passCriterion) }
            $0.submitTask = { _, _, _ in Fixture.done(.submit) }
            $0.releaseTask = { _, _, _ in Fixture.done(.release) }
            $0.heartbeatTask = { _, _ in Fixture.beat() }
        }
        return loop
    }

    @Test("a builder reads the briefing and announces its first criterion not passed, with no acknowledgement")
    func builderContinues() async throws {
        let harness = try Harness()
        let loop = builder(harness)
        harness.next([], then: loop)

        #expect(await runToEnd(loop) == 0)
        #expect(Array(harness.operations.filter { $0 != .heartbeatTask }.prefix(5)) == [
            .getTaskBriefing, .startCriterion, .passCriterion, .submitTask, .getNext,
        ])
        #expect(harness.calls(.getTaskBriefing).first?.id == taskID.contractString)
        #expect(harness.calls(.startCriterion).map(\.cid) == [secondID.contractString])
        #expect(harness.calls(.acknowledgeTaskBriefing).isEmpty)
        #expect(harness.calls(.claimNextTask).isEmpty)
    }

    @Test("it acknowledges once a call is refused briefing_not_acknowledged, then goes on",
          arguments: [RefusalCode.briefingNotAcknowledged, .briefingChanged])
    func acknowledgesWhenAsked(code: RefusalCode) async throws {
        let harness = try Harness()
        let refusals = Counter()
        let loop = builder(harness) { _ in
            refusals.increment() == 1 ? Fixture.refused(code, .startCriterion) : Fixture.done(.startCriterion)
        }
        harness.next([], then: loop)

        #expect(await runToEnd(loop) == 0)
        #expect(Array(harness.operations.filter { $0 != .heartbeatTask }.prefix(6)) == [
            .getTaskBriefing, .startCriterion, .getTaskBriefing, .acknowledgeTaskBriefing, .startCriterion,
            .passCriterion,
        ])
        #expect(harness.calls(.acknowledgeTaskBriefing).map { $0.body?["briefing_hash"]?.stringValue } == ["hash-held"])
        #expect(harness.calls(.submitTask).count == 1)
    }

    @Test("work that is no longer the seat's is dropped: no release, and the run polls as usual",
          arguments: [RefusalCode.notHolder, .leaseExpired, .taskCancelled])
    func dropsRefused(code: RefusalCode) async throws {
        let harness = try Harness()
        let loop = builder(harness) { _ in Fixture.refused(code, .startCriterion) }
        harness.next([], then: loop)

        #expect(await runToEnd(loop) == 0)
        #expect(harness.operations.filter { $0 != .heartbeatTask } == [.getTaskBriefing, .startCriterion, .getNext])
        #expect(harness.calls(.releaseTask).isEmpty)
    }

    @Test("a briefing refused not_holder, or a task that is gone (404), is dropped too")
    func dropsUnreadable() async throws {
        for failure in [
            LeverageClientError.refused(Refusal(code: .notHolder, ruleID: nil, reason: nil)) as any Error,
            TransportError(code: .notFound, message: "not found"),
        ] {
            let harness = try Harness()
            let loop = builder(harness)
            harness.api.script { $0.taskBriefing = { _ in throw failure } }
            harness.next([], then: loop)

            #expect(await runToEnd(loop) == 0)
            #expect(harness.operations.filter { $0 != .heartbeatTask } == [.getTaskBriefing, .getNext])
            #expect(harness.calls(.releaseTask).isEmpty)
        }
    }

    @Test("a stop while continuing gives the task back with stopping, as any held task")
    func stopWhileContinuing() async throws {
        let harness = try Harness()
        let driver = ScriptedDriver { _, _ in .block }
        let loop = harness.loop(.builder, driver: driver, continuing: .task(taskID))
        let briefing = BriefingResponse(
            briefing: Fixture.briefing(hash: "hash-held", criteria: criteria()),
            workReference: harness.existingWork.path)
        harness.api.script {
            $0.taskBriefing = { _ in briefing }
            $0.startCriterion = { _, _, _ in Fixture.done(.startCriterion) }
            $0.releaseTask = { _, _, _ in Fixture.done(.release) }
            $0.heartbeatTask = { _, _ in Fixture.beat() }
            $0.next = { _ in NextItem(kind: .none) }
        }
        let run = Task { await runToEnd(loop) }
        #expect(await eventually { driver.runs.count == 1 })
        loop.stop()
        #expect(await run.value == 0)
        #expect(harness.calls(.releaseTask).map { $0.body?["reason"]?.stringValue } == ["stopping"])
    }

    // MARK: A review

    func reviewer(
        _ harness: Harness,
        verdict: @escaping @Sendable () -> PlainOutcome = { Fixture.done(.failReview) }
    ) -> RunnerLoop {
        let loop = harness.loop(.reviewer, driver: ScriptedDriver { _, _ in
            .answer("LEVERAGE-CRITERION 1: PASS\nLEVERAGE-CRITERION 2: PASS\nLEVERAGE-NOTES: Fine.", tokens: 4)
        }, continuing: .review(reviewID))
        let passed = criteria().map {
            Fixture.criterion(taskID, $0.position, $0.text, state: .passed, id: $0.id)
        }
        let briefing = BriefingResponse(
            briefing: Fixture.briefing(hash: "review-held", criteria: passed, roleFile: "You review the work."),
            workReference: harness.existingWork.path)
        harness.api.script {
            $0.reviewBriefing = { _ in briefing }
            $0.acknowledgeReviewBriefing = { _, _, _ in Fixture.done(.acknowledgeReviewBriefing) }
            $0.giveVerdict = { _, _, _ in verdict() }
            $0.releaseReview = { _, _ in Fixture.done(.releaseReview) }
            $0.heartbeatReview = { _, _ in
                .completed(HeartbeatResult(leaseDueAt: Date().addingTimeInterval(3600)), key: "k",
                           command: .heartbeatReview)
            }
        }
        return loop
    }

    @Test("a reviewer reads the review's briefing and gives its verdict, with no acknowledgement")
    func reviewerContinues() async throws {
        let harness = try Harness()
        let loop = reviewer(harness)
        harness.next([], then: loop)

        #expect(await runToEnd(loop) == 0)
        #expect(harness.operations.filter { $0 != .heartbeatReview } == [.getReviewBriefing, .giveVerdict, .getNext])
        #expect(harness.calls(.getReviewBriefing).first?.id == reviewID.contractString)
        #expect(harness.calls(.claimNextReview).isEmpty)
    }

    @Test("a reviewer acknowledges once the verdict is refused briefing_not_acknowledged")
    func reviewerAcknowledgesWhenAsked() async throws {
        let harness = try Harness()
        let verdicts = Counter()
        let loop = reviewer(harness) {
            verdicts.increment() == 1
                ? Fixture.refused(.briefingNotAcknowledged, .failReview) : Fixture.done(.failReview)
        }
        harness.next([], then: loop)

        #expect(await runToEnd(loop) == 0)
        #expect(harness.operations.filter { $0 != .heartbeatReview } == [
            .getReviewBriefing, .giveVerdict, .getReviewBriefing, .acknowledgeReviewBriefing, .giveVerdict, .getNext,
        ])
    }

    @Test("a review that is no longer the seat's is dropped without a release")
    func reviewerDrops() async throws {
        let harness = try Harness()
        let loop = reviewer(harness) { Fixture.refused(.notHolder, .failReview) }
        harness.next([], then: loop)

        #expect(await runToEnd(loop) == 0)
        #expect(harness.operations.filter { $0 != .heartbeatReview } == [.getReviewBriefing, .giveVerdict, .getNext])
        #expect(harness.calls(.releaseReview).isEmpty)
    }

    // MARK: The model the start names

    @Test("the model flag carries the model the start names, and is absent when it names none")
    func modelFlag() async throws {
        let setup = try DriverTests.Setup()
        let claude = DriverTests.cases[0]
        try setup.signIn(claude)
        for model in ["claude-made-up-model", nil] as [String?] {
            var environment = setup.environment(claude, model: nil, effort: nil)
            environment["LEVERAGE_MODEL"] = model
            environment["LEVERAGE_CREDENTIAL_ID"] = UUID().contractString
            environment["LEVERAGE_CONTINUE_TASK_ID"] = taskID.contractString
            let configuration = try RunnerConfiguration(environment: environment)
            _ = try await ProcessToolDriver(tool: configuration.tool)
                .run(prompt: DriverTests.buildPrompt, in: setup.work, purpose: .build)
            let argv = try setup.lastCall().argv
            if let model {
                let index = try #require(argv.firstIndex(of: "--model"))
                #expect(argv.dropFirst(index + 1).first == model)
            } else {
                #expect(!argv.contains("--model"))
            }
        }
    }
}
