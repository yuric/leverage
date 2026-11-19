import Foundation
import LeverageKit
import LeverageTestSupport
import Testing

@testable import LeverageRunner

// What refusals, the next item, a stop and failures do to a flow (CL-22,
// CL-23, CL-31).
@Suite("Runner loop", .timeLimit(.minutes(1)))
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
        pass: @escaping @Sendable (UUID) -> PlainOutcome = { _ in Fixture.done(.passCriterion) }
    ) -> RunnerLoop {
        let loop = harness.loop(.builder, driver: driver, timing: timing)
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
            .getNext, .claimNextTask, .acknowledgeTaskBriefing, .startCriterion, .passCriterion, .getNext,
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
        let idle = Queue(Array(repeating: NextItem(kind: .none), count: 5)) {
            NextItem(kind: .resume, id: self.taskID.contractString)
        }
        let afterResume = Counter()
        harness.api.script { [loop] in
            $0.next = { _ in
                let item = idle.next()
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
        #expect(!operations[refused..<resumedAt].contains(.heartbeatTask))
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
        harness.next([NextItem(kind: .review), NextItem(kind: .command, id: "abc")], then: loop)

        #expect(await runToEnd(loop) == 0)
        #expect(harness.operations == [.getNext, .getNext, .getNext])
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
