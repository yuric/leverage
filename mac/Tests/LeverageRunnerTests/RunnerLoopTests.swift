import Foundation
import LeverageKit
import LeverageTestSupport
import Testing

@testable import LeverageRunner

// What refusals, the next item, a stop and failures do to a flow (CL-22,
// CL-23, CL-31).
@Suite("Runner loop", .timeLimit(.minutes(Patience.minutes(1))))
struct RunnerLoopTests {
    let taskID = UUID()
    let firstID = UUID()
    let secondID = UUID()

    func criteria(first: CriterionState = .open) -> [Criterion] {
        [
            Fixture.criterion(taskID, 1, "The copy names this year's prices.", state: first, id: firstID),
            Fixture.criterion(taskID, 2, "The layout matches the rest of the site.", id: secondID),
        ]
    }

    func builder(
        _ harness: Harness, driver: any ToolDriver = ScriptedDriver.agreeable(), timing: RunnerTiming = .fast(),
        role: SeatRole = .builder,
        pass: @escaping @Sendable (UUID) -> PlainOutcome = { _ in Fixture.done(.passCriterion) }
    ) -> RunnerLoop {
        let loop = harness.loop(role, driver: driver, timing: timing)
        let claim = Fixture.claim(taskID, criteria: criteria(), workReference: harness.existingWork.path)
        harness.api.script {
            $0.claimNextTask = { _ in .completed(claim, key: "k", command: .claim) }
            $0.acknowledgeTaskBriefing = { _, _, _ in Fixture.done(.acknowledgeBriefing) }
            $0.startCriterion = { _, _, _ in Fixture.done(.startCriterion) }
            $0.passCriterion = { _, cid, _, _ in pass(cid) }
            $0.submitTask = { _, _, _ in Fixture.done(.submit) }
            $0.releaseTask = { _, _, _ in Fixture.done(.release) }
            $0.heartbeatTask = { _, _ in Fixture.beat() }
        }
        return loop
    }

    @Test("briefing_changed on a command re-reads the briefing, acknowledges it and goes on")
    func briefingChangedRefusal() async throws {
        let harness = try Harness()
        let refusedOnce = Counter()
        let loop = builder(harness) { _ in
            refusedOnce.increment() == 1
                ? Fixture.refused(.briefingChanged, .passCriterion) : Fixture.done(.passCriterion)
        }
        let changed = BriefingResponse(
            briefing: Fixture.briefing(hash: "hash-changed", criteria: criteria()),
            workReference: harness.existingWork.path)
        harness.api.script { $0.taskBriefing = { _ in changed } }
        harness.next([NextItem(kind: .task)], then: loop)

        #expect(await runToEnd(loop) == 0)
        let acks = harness.calls(.acknowledgeTaskBriefing).map { $0.body?["briefing_hash"]?.stringValue }
        #expect(acks == ["hash-0", "hash-changed"])
        let afterRefusal = Array(harness.operations.drop { $0 != .getTaskBriefing })
        #expect(afterRefusal.first == .getTaskBriefing)
        #expect(afterRefusal.dropFirst().first == .acknowledgeTaskBriefing)
        #expect(harness.calls(.submitTask).count == 1)
        #expect(harness.calls(.releaseTask).isEmpty)
    }

    @Test("a briefing_changed item re-reads and acknowledges the held task's briefing")
    func briefingChangedItem() async throws {
        let harness = try Harness()
        let loop = builder(harness)
        let changed = BriefingResponse(
            briefing: Fixture.briefing(hash: "hash-changed", criteria: criteria(first: .passed)),
            workReference: harness.existingWork.path)
        harness.api.script { $0.taskBriefing = { _ in changed } }
        harness.next([NextItem(kind: .briefingChanged, id: taskID.contractString)], then: loop)

        #expect(await runToEnd(loop) == 0)
        #expect(harness.operations.prefix(3) == [.getNext, .getTaskBriefing, .acknowledgeTaskBriefing])
        #expect(harness.calls(.acknowledgeTaskBriefing).first?.body?["briefing_hash"]?.stringValue == "hash-changed")
        #expect(harness.calls(.startCriterion).map(\.cid) == [secondID.contractString])
    }

    @Test("lease_expired ends the flow: no release, no submit")
    func leaseExpired() async throws {
        let harness = try Harness()
        let loop = builder(harness) { _ in Fixture.refused(.leaseExpired, .passCriterion) }
        harness.next([NextItem(kind: .task)], then: loop)

        #expect(await runToEnd(loop) == 0)
        #expect(harness.operations == [
            .getNext, .claimNextTask, .acknowledgeTaskBriefing, .startCriterion, .reportCost, .passCriterion, .getNext,
        ])
    }

    @Test("lease_expired on a heartbeat ends the tool and the flow")
    func leaseExpiredHeartbeat() async throws {
        let harness = try Harness()
        let driver = ScriptedDriver { _, _ in .block }
        let loop = builder(harness, driver: driver, timing: .fast(heartbeatEvery: .milliseconds(20)))
        harness.api.script {
            $0.heartbeatTask = { _, _ in
                .refused(Refusal(code: .leaseExpired, ruleID: nil, reason: nil), key: "k", command: .heartbeat)
            }
        }
        harness.next([NextItem(kind: .task)], then: loop)

        #expect(await runToEnd(loop) == 0)
        #expect(driver.cancelledRuns == 1)
        #expect(harness.calls(.releaseTask).isEmpty)
        #expect(harness.calls(.passCriterion).isEmpty)
    }

    @Test("on_hold pauses the flow and stops heartbeating; resume continues it from its briefing")
    func onHoldThenResume() async throws {
        let harness = try Harness()
        let passes = Counter()
        let loop = builder(harness, timing: .fast(heartbeatEvery: .milliseconds(10))) { _ in
            passes.increment() == 1 ? Fixture.refused(.onHold, .passCriterion) : Fixture.done(.passCriterion)
        }
        let resumed = BriefingResponse(
            briefing: Fixture.briefing(hash: "hash-resumed", criteria: criteria()),
            workReference: harness.existingWork.path)
        harness.api.script { $0.taskBriefing = { _ in resumed } }
        // While held, the next item is `none`, several times, slowly enough
        // that a heartbeat on a 10 ms timer would have shown.
        let idle = Queue([NextItem(kind: .task)] + Array(repeating: NextItem(kind: .none), count: 5)) {
            NextItem(kind: .resume, id: self.taskID.contractString)
        }
        let afterResume = Counter()
        harness.api.script { [loop] in
            $0.next = { _ in
                let item = idle.next()
                if item.kind == .task { return item }
                if item.kind == .none {
                    try? await Task.sleep(for: .milliseconds(30))
                    return item
                }
                if afterResume.increment() > 1 {
                    loop.stop()
                    return NextItem(kind: .none)
                }
                return item
            }
        }

        #expect(await runToEnd(loop) == 0)
        let operations = harness.operations
        let refused = try #require(operations.firstIndex(of: .passCriterion))
        let resumedAt = try #require(operations.firstIndex(of: .getTaskBriefing))
        // A heartbeat already on its way when the refusal came back may still
        // land; once the runner asks for its next item, none is sent while held.
        let held = try #require(operations[refused..<resumedAt].firstIndex(of: .getNext))
        #expect(!operations[held..<resumedAt].contains(.heartbeatTask))
        #expect(operations[refused..<held].filter { $0 == .heartbeatTask }.count <= 1)
        #expect(operations[resumedAt..<operations.endIndex].prefix(2) == [
            .getTaskBriefing, .acknowledgeTaskBriefing,
        ])
        #expect(harness.calls(.submitTask).count == 1)
        #expect(harness.calls(.releaseTask).isEmpty)
        #expect(harness.calls(.acknowledgeTaskBriefing).last?.body?["briefing_hash"]?.stringValue == "hash-resumed")
    }

    @Test("task_cancelled ends the flow and the tool at once")
    func taskCancelled() async throws {
        let harness = try Harness()
        let driver = ScriptedDriver { _, _ in .block }
        let loop = builder(harness, driver: driver, timing: .fast(heartbeatEvery: .milliseconds(20)))
        harness.api.script {
            $0.heartbeatTask = { _, _ in
                .refused(Refusal(code: .taskCancelled, ruleID: nil, reason: nil), key: "k", command: .heartbeat)
            }
        }
        harness.next([NextItem(kind: .task)], then: loop)

        #expect(await runToEnd(loop) == 0)
        #expect(driver.cancelledRuns == 1)
        #expect(harness.calls(.releaseTask).isEmpty)
        #expect(harness.calls(.submitTask).isEmpty)
    }

    @Test("task_cancelled on a command ends the flow without a release")
    func taskCancelledCommand() async throws {
        let harness = try Harness()
        let loop = builder(harness) { _ in Fixture.refused(.taskCancelled, .passCriterion) }
        harness.next([NextItem(kind: .task)], then: loop)

        #expect(await runToEnd(loop) == 0)
        #expect(harness.calls(.releaseTask).isEmpty)
        #expect(harness.calls(.startCriterion).count == 1)
    }

    @Test("a stop ends the tool, releases the task with stopping and exits 0 (CL-23)")
    func stopReleasesTask() async throws {
        let harness = try Harness()
        let driver = ScriptedDriver { _, _ in .block }
        let loop = builder(harness, driver: driver)
        harness.api.script { $0.next = { _ in NextItem(kind: .task) } }
        let run = Task { await runToEnd(loop) }
        #expect(await eventually { driver.runs.count == 1 })
        loop.stop()

        #expect(await run.value == 0)
        #expect(driver.cancelledRuns == 1)
        let releases = harness.calls(.releaseTask)
        #expect(releases.count == 1)
        #expect(releases.first?.body?["reason"]?.stringValue == "stopping")
        #expect(releases.first?.id == taskID.contractString)
    }

    @Test("an answer for a known task is read once before the next poll")
    func questionAnswer() async throws {
        let harness = try Harness()
        let questionID = UUID()
        let taskID = self.taskID
        let answer = Question(
            id: questionID, taskID: taskID, askingSeatID: Fixture.seatID, text: "Which demo?",
            assumption: "The blue one.", blocking: true, outcome: .answered, answer: "Use the blue demo.", basis: .record)
        let loop = harness.loop(.builder, driver: ScriptedDriver.agreeable(), continuing: .task(taskID))
        harness.api.script {
            $0.taskBriefing = { _ in throw LeverageClientError.refused(Refusal(code: .onHold, ruleID: nil, reason: nil)) }
            $0.getQuestion = { _, _ in answer }
            $0.releaseTask = { _, _, _ in Fixture.done(.release) }
        }
        harness.next([NextItem(kind: .answer, id: questionID.contractString)], then: loop)

        #expect(await runToEnd(loop) == 0)
        let calls = harness.calls(.getQuestion)
        #expect(calls.count == 1)
        #expect(calls.first?.path == ["id": taskID.contractString, "qid": questionID.contractString])
        #expect(harness.operations.prefix(4) == [.getTaskBriefing, .getNext, .getQuestion, .getNext])
    }

    @Test("a stop while holding nothing releases nothing")
    func stopIdle() async throws {
        let harness = try Harness()
        let loop = harness.loop(.builder, driver: ScriptedDriver.agreeable())
        harness.next([NextItem(kind: .none)], then: loop)

        #expect(await runToEnd(loop) == 0)
        #expect(harness.operations == [.getNext, .getNext])
    }

    @Test("401 on the next item exits with code 3")
    func unauthenticated() async throws {
        let harness = try Harness()
        let loop = harness.loop(.builder, driver: ScriptedDriver.agreeable())
        harness.api.script {
            $0.next = { _ in throw TransportError(code: .unauthenticated, message: "Sign in again.") }
        }

        #expect(await runToEnd(loop) == 3)
    }

    @Test("401 in the middle of a flow exits with code 3")
    func unauthenticatedInFlow() async throws {
        let harness = try Harness()
        let loop = builder(harness)
        harness.api.script {
            $0.startCriterion = { _, _, _ in throw TransportError(code: .unauthenticated, message: "Sign in again.") }
        }
        harness.api.script { $0.next = { _ in NextItem(kind: .task) } }

        #expect(await runToEnd(loop) == 3)
    }

    @Test("an error from the next item is followed by a short pause and another ask")
    func nextError() async throws {
        let harness = try Harness()
        let loop = harness.loop(.builder, driver: ScriptedDriver.agreeable())
        let asks = Counter()
        harness.api.script { [loop] in
            $0.next = { _ in
                switch asks.increment() {
                case 1, 2: throw URLError(.cannotConnectToHost)
                case 3: return NextItem(kind: .none)
                default: loop.stop(); return NextItem(kind: .none)
                }
            }
        }

        #expect(await runToEnd(loop) == 0)
        #expect(asks.value == 4)
    }

    @Test("a network failure of a command is retried with the same key")
    func retrySameKey() async throws {
        let harness = try Harness()
        let failures = Counter()
        let loop = builder(harness)
        harness.api.script {
            $0.startCriterion = { _, _, _ in
                if failures.increment() == 1 { throw URLError(.networkConnectionLost) }
                return Fixture.done(.startCriterion)
            }
        }
        harness.next([NextItem(kind: .task)], then: loop)

        #expect(await runToEnd(loop) == 0)
        let starts = harness.calls(.startCriterion)
        #expect(starts.count == 3)
        #expect(starts[0].key == starts[1].key)
        #expect(starts[1].key != starts[2].key)
        #expect(harness.calls(.submitTask).count == 1)
    }

    @Test("three failed tool runs in a row exit with code 4 (CL-22)")
    func threeFailures() async throws {
        let harness = try Harness()
        let driver = ScriptedDriver { _, _ in .fail(.exited(1)) }
        let loop = builder(harness, driver: driver)
        harness.api.script { $0.next = { _ in NextItem(kind: .task) } }

        #expect(await runToEnd(loop) == 4)
        #expect(driver.runs.count == 3)
        #expect(harness.calls(.releaseTask).count == 3)
        #expect(harness.calls(.releaseTask).allSatisfy { $0.body?["reason"]?.stringValue == "unable_to_continue" })
    }

    @Test("a good tool run in between starts the count again")
    func failuresNotInARow() async throws {
        let harness = try Harness()
        let runs = Counter()
        // Fail, fail, succeed (both criteria), fail, fail: never three in a row.
        let driver = ScriptedDriver { _, _ in
            switch runs.increment() {
            case 3, 4: .answer("LEVERAGE-EVIDENCE: proof.txt", tokens: 1)
            default: .fail(.exited(1))
            }
        }
        let loop = builder(harness, driver: driver)
        let tasks = Queue(Array(repeating: NextItem(kind: .task), count: 5)) { NextItem(kind: .none) }
        harness.api.script { [loop] in
            $0.next = { _ in
                if runs.value >= 6 { loop.stop() }
                return tasks.next()
            }
        }

        #expect(await runToEnd(loop) == 0)
        #expect(driver.runs.count == 6)
    }

    @Test("an item the builder cannot act on is followed by a pause, not a call")
    func otherKinds() async throws {
        let harness = try Harness()
        let loop = harness.loop(.builder, driver: ScriptedDriver.agreeable())
        harness.next([NextItem(kind: .review), NextItem(kind: .job), NextItem(kind: .command)], then: loop)

        #expect(await runToEnd(loop) == 0)
        #expect(harness.operations == [.getNext, .getNext, .getNext, .getNext])
    }

    @Test("General finishes a job, a review and a task in one loop")
    func generalDoesEachKindInTurn() async throws {
        let harness = try Harness()
        let driver = ScriptedDriver { prompt, purpose in
            switch purpose {
            case .check:
                let nonce = JobFixture.nonce(of: prompt) ?? ""
                return .answer("LEVERAGE-VERDICT-\(nonce): PASSED\nLEVERAGE-REASON-\(nonce): It names the page.", tokens: 7)
            case .review:
                return .answer("LEVERAGE-CRITERION 1: PASS", tokens: 3)
            case .build:
                return .answer("LEVERAGE-EVIDENCE: proof.txt in the work folder", tokens: 5)
            }
        }
        let loop = builder(harness, driver: driver, role: .general)
        let job = JobFixture.checkClaim()
        let reviewedTaskID = UUID()
        let review = Fixture.reviewClaim(
            UUID(), taskID: reviewedTaskID,
            criteria: [Fixture.criterion(reviewedTaskID, 1, "The page names the discount.", state: .passed)],
            workReference: harness.existingWork.path)
        harness.api.script {
            $0.claimNextJob = { key in .completed(job, key: key.value, command: .claimJob) }
            $0.submitJobResult = { _, _, _ in Fixture.done(.submitJobResult) }
            $0.claimNextReview = { key in .completed(review, key: key.value, command: .claimReview) }
            $0.acknowledgeReviewBriefing = { _, _, _ in Fixture.done(.acknowledgeReviewBriefing) }
            $0.giveVerdict = { _, _, _ in Fixture.done(.passReview) }
        }
        harness.next([NextItem(kind: .job), NextItem(kind: .review), NextItem(kind: .task)], then: loop)

        #expect(await runToEnd(loop) == 0)
        #expect(harness.operations == [
            .getNext, .claimNextJob, .submitJobResult,
            .getNext, .claimNextReview, .acknowledgeReviewBriefing, .giveVerdict,
            .getNext, .claimNextTask, .acknowledgeTaskBriefing, .startCriterion, .reportCost, .passCriterion,
            .startCriterion, .reportCost, .passCriterion, .submitTask, .getNext,
        ])
        #expect(driver.runs.map(\.purpose) == [.check, .review, .build, .build])
        #expect(harness.calls(.giveVerdict).first?.body?["verdict"]?.stringValue == "passed")
    }

    @Test("General on Gemini passes over a review offer and still asks for jobs and tasks")
    func generalGeminiPassesOverReview() async throws {
        let harness = try Harness()
        let driver = ScriptedDriver.agreeable()
        let loop = harness.loop(.general, driver: driver, interruption: .init(provider: .gemini, hasCredential: true))
        harness.api.script {
            $0.claimNextJob = { key in .completed(nil, key: key.value, command: .claimJob) }
            $0.claimNextTask = { key in
                .refused(Refusal(code: .notEligible, ruleID: nil, reason: nil), key: key.value, command: .claim)
            }
        }
        harness.next([NextItem(kind: .review), NextItem(kind: .job), NextItem(kind: .task)], then: loop)

        #expect(await runToEnd(loop) == 0)
        #expect(harness.operations == [.getNext, .getNext, .claimNextJob, .getNext, .claimNextTask, .getNext])
        #expect(driver.runs.isEmpty)
    }

    @Test("General on Gemini releases a held review with no body", arguments: [false, true])
    func generalGeminiReleasesReview(atStartup: Bool) async throws {
        let harness = try Harness()
        let reviewID = UUID()
        let driver = ScriptedDriver.agreeable()
        let loop = harness.loop(
            .general, driver: driver, interruption: .init(provider: .gemini, hasCredential: true),
            continuing: atStartup ? .review(reviewID) : nil)
        let claim = Fixture.reviewClaim(
            reviewID, taskID: taskID, criteria: Array(criteria(first: .passed).prefix(1)),
            workReference: harness.existingWork.path)
        let briefing = BriefingResponse(briefing: claim.briefing, workReference: claim.workReference)
        harness.api.script {
            $0.reviewBriefing = { _ in briefing }
            $0.giveVerdict = { _, _, _ in Fixture.done(.passReview) }
            $0.releaseReview = { _, _ in Fixture.done(.releaseReview) }
        }
        let changed = NextItem(kind: .briefingChanged, id: taskID.contractString, reviewID: reviewID)
        harness.next(atStartup ? [] : [changed], then: loop)

        #expect(await runToEnd(loop) == 0)
        #expect(harness.operations == (atStartup ? [.releaseReview, .getNext] : [.getNext, .releaseReview, .getNext]))
        #expect(driver.runs.isEmpty)
        let release = try #require(harness.calls(.releaseReview).first)
        #expect(release.id == reviewID.contractString)
        #expect(release.body == nil)
    }

    @Test("a General run leaves the work folder's files and folders alone")
    func generalWritesNoRoleOrSkillFiles() async throws {
        let harness = try Harness()
        let workFolder = harness.existingWork
        let existingFile = workFolder.appendingPathComponent("draft.txt")
        try Data("Work in progress.".utf8).write(to: existingFile)
        let driver = ScriptedDriver.agreeable()
        let loop = harness.loop(.general, driver: driver, continuing: .task(taskID))
        let briefing = Briefing(
            hash: "hash-0", versions: BriefingVersions(roleFileVersion: nil, contractVersion: 1), roleFile: nil,
            contract: BriefingContract(contractVersion: 1, goal: "Update the prices.", details: nil, criteria: criteria()))
        let response = BriefingResponse(briefing: briefing, workReference: workFolder.path)
        harness.api.script {
            $0.taskBriefing = { _ in response }
            $0.startCriterion = { _, _, _ in Fixture.done(.startCriterion) }
            $0.passCriterion = { _, _, _, _ in Fixture.done(.passCriterion) }
            $0.submitTask = { _, _, _ in Fixture.done(.submit) }
        }
        harness.next([], then: loop)

        #expect(await runToEnd(loop) == 0)
        #expect(driver.runs.map(\.folder) == [workFolder, workFolder])
        #expect(harness.calls(.submitTask).count == 1)
        #expect(try FileManager.default.subpathsOfDirectory(atPath: workFolder.path) == ["draft.txt"])
        #expect(try Data(contentsOf: existingFile) == Data("Work in progress.".utf8))
    }

    // Milestone 4: a `command` item names a command of this seat whose
    // outcome changed after it stopped waiting on it; reading it once clears
    // the item, which would otherwise repeat (plan section 2.2, RunnerLoop).
    @Test("a command item is read once by its key, for every role", arguments: SeatRole.allCases)
    func commandItem(role: SeatRole) async throws {
        let harness = try Harness()
        let loop = harness.loop(role, driver: ScriptedDriver.agreeable())
        harness.api.script {
            $0.command = { key in .completed(.object([:]), key: key.value, command: .submitJobResult) }
        }
        harness.next([NextItem(kind: .command, id: "made-up-key-1")], then: loop)

        #expect(await runToEnd(loop) == 0)
        #expect(harness.operations == [.getNext, .getCommand, .getNext])
        #expect(harness.calls(.getCommand).first?.path["key"] == "made-up-key-1")
    }

    @Test("the loop asks with the long poll's wait")
    func longPoll() async throws {
        let harness = try Harness()
        var timing = RunnerTiming.fast()
        timing.nextWait = 30
        let loop = harness.loop(.builder, driver: ScriptedDriver.agreeable(), timing: timing)
        let seen = LockedValues()
        harness.api.script { [loop] in
            $0.next = { wait in
                seen.append(wait)
                loop.stop()
                return NextItem(kind: .none)
            }
        }

        #expect(await runToEnd(loop) == 0)
        #expect(seen.values == [30])
    }

    @Test("the standard timing never pauses longer than 2 seconds (CL-31)")
    func standardTiming() {
        let timing = RunnerTiming.standard
        #expect(timing.errorPause <= .seconds(2))
        #expect(timing.idlePause <= .seconds(2))
        #expect(timing.nextWait == 30)
        // A busy job seat asks every 30 seconds, well inside the 90 seconds
        // after which it counts as offline (RD-15).
        #expect(timing.jobPollInterval == .seconds(30))
        let now = Date()
        #expect(timing.heartbeatInterval(now.addingTimeInterval(3600), now) == .seconds(600))
        #expect(timing.heartbeatInterval(now.addingTimeInterval(90), now) == .seconds(30))
        #expect(timing.heartbeatInterval(now.addingTimeInterval(1), now) == .seconds(1))
        #expect(timing.heartbeatInterval(now.addingTimeInterval(-10), now) == .seconds(1))
    }
}

final class LockedValues: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Int?] = []
    func append(_ value: Int?) { lock.withLock { stored.append(value) } }
    var values: [Int?] { lock.withLock { stored } }
}
