import Foundation
import LeverageKit
import LeverageTestSupport
import Testing

@testable import LeverageRunner

// A planner's and an orchestrator's loop (milestone 4 plan section 2.2,
// RD-15, RD-40): claim the next job, run it, submit the result once; keep
// polling while the tool runs; a limit during a job's run ends the run and
// names the job.
@Suite("Job flow", .timeLimit(.minutes(Patience.minutes(1))))
struct JobFlowTests {
    func scriptSubmit(_ harness: Harness) {
        harness.api.script {
            $0.submitJobResult = { _, _, key in .completed(.object([:]), key: key.value, command: .submitJobResult) }
        }
    }

    @Test("an orchestrator claims a rule check, runs it and submits the verdict once")
    func orchestrator() async throws {
        let harness = try Harness()
        let jobID = UUID()
        let claim = JobFixture.checkClaim(jobID: jobID)
        let loop = harness.loop(.orchestrator, driver: JobFixture.answering("PASSED", reason: "It names the page."))
        harness.api.script { $0.claimNextJob = { key in .completed(claim, key: key.value, command: .claimJob) } }
        scriptSubmit(harness)
        harness.next([NextItem(kind: .job)], then: loop)

        #expect(await runToEnd(loop) == 0)
        #expect(harness.operations == [.getNext, .claimNextJob, .submitJobResult, .getNext])
        let submit = try #require(harness.calls(.submitJobResult).first)
        #expect(submit.id == jobID.contractString)
        #expect(submit.body?["result"]?["result"]?.stringValue == "passed")
        #expect(submit.body?["result"]?["reason"]?.stringValue == "It names the page.")
        #expect(submit.body?["tokens"]?.numberValue == 7)
        #expect(submit.body?["spend"]?.numberValue == 0)
    }

    @Test("a planner claims a draft and submits the contract, the stored values unchanged")
    func planner() async throws {
        let harness = try Harness()
        let driver = ScriptedDriver { prompt, _ in
            let nonce = JobFixture.nonce(of: prompt) ?? ""
            return .answer(
                "LEVERAGE-DRAFT-\(nonce)-BEGIN\n{\"details\": null, \"criteria\": [\"One.\"]}\nLEVERAGE-DRAFT-\(nonce)-END", tokens: 2)
        }
        let loop = harness.loop(.planner, driver: driver)
        let claim = JobFixture.draftClaim(JobFixture.draftInput(JobFixture.draftMaterial(details: nil)))
        harness.api.script { $0.claimNextJob = { key in .completed(claim, key: key.value, command: .claimJob) } }
        scriptSubmit(harness)
        harness.next([NextItem(kind: .job)], then: loop)

        #expect(await runToEnd(loop) == 0)
        let result = try #require(harness.calls(.submitJobResult).first?.body?["result"])
        #expect(result["title"]?.stringValue == JobFixture.title)
        #expect(result["details"] == .null)
        #expect(result["goal"] == nil)
        #expect(result["work_reference"]?.stringValue == "/Users/example/sites/alpaca")
        #expect(result["minimum_strength_rank"]?.numberValue == 2)
        #expect(result["budget_cap"]?.numberValue == 12.5)
        #expect(result["criteria"]?[0]?["kind"]?.stringValue == "build")
        #expect(result["criteria"]?[0]?["text"]?.stringValue == "One.")
    }

    @Test("a planner's contract that answers pending is not waited on: the job is done")
    func pendingContract() async throws {
        let harness = try Harness()
        let driver = ScriptedDriver { prompt, _ in
            let nonce = JobFixture.nonce(of: prompt) ?? ""
            return .answer(
                """
                LEVERAGE-DRAFT-\(nonce)-BEGIN
                {"details": "Update the prices from the supplied figures.", "criteria": ["One."]}
                LEVERAGE-DRAFT-\(nonce)-END
                """,
                tokens: 2)
        }
        let loop = harness.loop(.planner, driver: driver)
        let claim = JobFixture.draftClaim()
        harness.api.script {
            $0.claimNextJob = { key in .completed(claim, key: key.value, command: .claimJob) }
            $0.submitJobResult = { _, _, key in .pending(key: key.value, command: .submitJobResult) }
        }
        harness.next([NextItem(kind: .job)], then: loop)

        #expect(await runToEnd(loop) == 0)
        #expect(harness.operations == [.getNext, .claimNextJob, .submitJobResult, .getNext])
    }

    @Test("no verdict: nothing is submitted, and the job runs into its timeout")
    func noVerdict() async throws {
        let harness = try Harness()
        let driver = ScriptedDriver { _, _ in .answer("Looks fine to me.", tokens: 1) }
        let loop = harness.loop(.orchestrator, driver: driver)
        let claim = JobFixture.checkClaim()
        harness.api.script { $0.claimNextJob = { key in .completed(claim, key: key.value, command: .claimJob) } }
        harness.next([NextItem(kind: .job)], then: loop)

        #expect(await runToEnd(loop) == 0)
        #expect(harness.operations == [.getNext, .claimNextJob, .getNext])
        #expect(driver.runs.count == 2)
    }

    @Test("a refused result is not sent again")
    func refusedResult() async throws {
        let harness = try Harness()
        let loop = harness.loop(.orchestrator, driver: JobFixture.answering("PASSED"))
        let claim = JobFixture.checkClaim()
        harness.api.script {
            $0.claimNextJob = { key in .completed(claim, key: key.value, command: .claimJob) }
            $0.submitJobResult = { _, _, key in
                .refused(Refusal(code: .invalidState, ruleID: nil, reason: nil), key: key.value,
                         command: .submitJobResult)
            }
        }
        harness.next([NextItem(kind: .job)], then: loop)

        #expect(await runToEnd(loop) == 0)
        #expect(harness.calls(.submitJobResult).count == 1)
    }

    @Test("a claim that returns the job the seat already holds continues it (RD-40)")
    func heldJob() async throws {
        let harness = try Harness()
        let jobID = UUID()
        let claim = JobFixture.checkClaim(jobID: jobID)
        let runs = Counter()
        let driver = ScriptedDriver { prompt, _ in
            // The first run is cut short (no verdict); the claim after it
            // returns the same job, which is run and answered.
            if runs.increment() <= 2 { return .answer("Interrupted.", tokens: 0) }
            let nonce = JobFixture.nonce(of: prompt) ?? ""
            return .answer("LEVERAGE-VERDICT-\(nonce): PASSED\nLEVERAGE-REASON-\(nonce): Fine.", tokens: 1)
        }
        let loop = harness.loop(.orchestrator, driver: driver)
        harness.api.script { $0.claimNextJob = { key in .completed(claim, key: key.value, command: .claimJob) } }
        scriptSubmit(harness)
        harness.next([NextItem(kind: .job), NextItem(kind: .job)], then: loop)

        #expect(await runToEnd(loop) == 0)
        #expect(harness.calls(.claimNextJob).count == 2)
        #expect(harness.calls(.submitJobResult).map(\.id) == [jobID.contractString])
    }

    @Test("while a check's tool runs for 100 seconds of a test clock, GET /v1/next is asked at least three times, with no wait, and no more once the tool ends (RD-15)")
    func pollsWhileTheToolRuns() async throws {
        let harness = try Harness()
        let clock = TestClock()
        let polls = Counter()
        let ended = Counter()
        let driver = ScriptedDriver(request: { request in
            for _ in 0..<100 {
                clock.advance(by: 1)
                try? await Task.sleep(for: .milliseconds(2))
            }
            ended.increment()
            let nonce = JobFixture.nonce(of: request.prompt) ?? ""
            return .answer("LEVERAGE-VERDICT-\(nonce): PASSED\nLEVERAGE-REASON-\(nonce): Fine.", tokens: 1)
        })
        let claim = JobFixture.checkClaim(runDueAt: clock.now.addingTimeInterval(300))
        let waits = LockedValues()
        harness.api.script {
            $0.claimNextJob = { key in .completed(claim, key: key.value, command: .claimJob) }
            $0.submitJobResult = { _, _, key in .completed(.object([:]), key: key.value, command: .submitJobResult) }
            $0.next = { wait in
                waits.append(wait)
                polls.increment()
                return NextItem(kind: .job)
            }
        }
        let flow = JobFlow(context: harness.context(driver: driver, timing: clock.timing(poll: .seconds(30))))

        let end = try await flow.claim()

        #expect(end == .finished)
        #expect(ended.value == 1)
        let asked = polls.value
        #expect(asked >= 3)
        #expect(waits.values.allSatisfy { $0 == 0 })
        try await Task.sleep(for: .milliseconds(100))
        clock.advance(by: 120)
        try await Task.sleep(for: .milliseconds(100))
        #expect(polls.value == asked, "no ask after the tool ended")
    }

    @Test("an error from the poll does not stop the job")
    func pollError() async throws {
        let harness = try Harness()
        let clock = TestClock()
        let driver = ScriptedDriver(request: { request in
            for _ in 0..<70 {
                clock.advance(by: 1)
                try? await Task.sleep(for: .milliseconds(2))
            }
            let nonce = JobFixture.nonce(of: request.prompt) ?? ""
            return .answer("LEVERAGE-VERDICT-\(nonce): FAILED\nLEVERAGE-REASON-\(nonce): Vague.", tokens: 1)
        })
        let claim = JobFixture.checkClaim(runDueAt: clock.now.addingTimeInterval(300))
        harness.api.script {
            $0.claimNextJob = { key in .completed(claim, key: key.value, command: .claimJob) }
            $0.submitJobResult = { _, _, key in .completed(.object([:]), key: key.value, command: .submitJobResult) }
            $0.next = { _ in throw URLError(.notConnectedToInternet) }
        }
        let end = try await JobFlow(context: harness.context(driver: driver, timing: clock.timing())).claim()
        #expect(end == .finished)
        #expect(harness.calls(.submitJobResult).count == 1)
    }

    @Test("a job's run that meets a limit ends the run with code 5 and a report naming the job; nothing is sent")
    func limit() async throws {
        let harness = try Harness()
        let jobID = UUID()
        let record = try ReplyFile("claude", "run-limit-five-hour.json").record
        let driver = ScriptedDriver { _, _ in .failRun(.exited(1), record) }
        let interruption = Interruption(
            provider: .claude, hasCredential: true, waits: InterruptionTests.noWaits,
            signInStatus: StatusAnswers(.signedIn).check)
        let loop = harness.loop(.orchestrator, driver: driver, interruption: interruption)
        let claim = JobFixture.checkClaim(jobID: jobID)
        harness.api.script { $0.claimNextJob = { key in .completed(claim, key: key.value, command: .claimJob) } }
        harness.next([NextItem(kind: .job)], then: loop)

        #expect(await runToEnd(loop) == RunnerExit.accountStopped.rawValue)
        let report = try #require(loop.endReport)
        #expect(report.jobID == jobID && report.taskID == nil && report.reviewID == nil)
        #expect(harness.calls(.submitJobResult).isEmpty)
        #expect(harness.operations == [.getNext, .claimNextJob])
    }

    @Test("a refused claim, or one with nothing to claim, goes back to asking what is next")
    func refusedClaim() async throws {
        let harness = try Harness()
        let loop = harness.loop(.planner, driver: JobFixture.answering("PASSED"))
        let tries = Counter()
        harness.api.script {
            $0.claimNextJob = { key in
                tries.increment() == 1
                    ? .refused(Refusal(code: .notEligible, ruleID: nil, reason: nil), key: key.value, command: .claimJob)
                    : .completed(nil, key: key.value, command: .claimJob)
            }
        }
        harness.next([NextItem(kind: .job), NextItem(kind: .job)], then: loop)

        #expect(await runToEnd(loop) == 0)
        #expect(harness.operations == [.getNext, .claimNextJob, .getNext, .claimNextJob, .getNext])
    }

    @Test("the job roles claim jobs only; a builder and a reviewer never claim one")
    func roles() async throws {
        for role in [SeatRole.orchestrator, .planner] {
            let harness = try Harness()
            let loop = harness.loop(role, driver: ScriptedDriver.agreeable())
            harness.next([NextItem(kind: .task), NextItem(kind: .review)], then: loop)
            #expect(await runToEnd(loop) == 0)
            #expect(harness.operations == [.getNext, .getNext, .getNext])
        }
        for role in [SeatRole.builder, .reviewer] {
            let harness = try Harness()
            let loop = harness.loop(role, driver: ScriptedDriver.agreeable())
            harness.next([NextItem(kind: .job)], then: loop)
            #expect(await runToEnd(loop) == 0)
            #expect(harness.operations == [.getNext, .getNext])
        }
    }

    @Test("a stop while a job's tool runs ends the tool and exits 0; there is nothing to give back")
    func stop() async throws {
        let harness = try Harness()
        let driver = ScriptedDriver { _, _ in .block }
        let loop = harness.loop(.orchestrator, driver: driver)
        let claim = JobFixture.checkClaim()
        harness.api.script {
            $0.claimNextJob = { key in .completed(claim, key: key.value, command: .claimJob) }
            $0.next = { _ in NextItem(kind: .job) }
        }
        let run = Task { await runToEnd(loop) }
        #expect(await eventually { driver.runs.count == 1 })
        loop.stop()
        #expect(await run.value == 0)
        #expect(driver.cancelledRuns == 1)
        #expect(harness.calls(.submitJobResult).isEmpty)
    }
}
