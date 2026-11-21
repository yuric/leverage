import Foundation
import LeverageKit
import LeverageTestSupport
import Testing

// The whole loop with stand-in tools (milestone 2 plan §5.2, TS-9): the real
// API in its containers, the real helper and the real runner, every
// provider's tool a stand-in. They run only with LEVERAGE_E2E=1, which
// scripts/e2e_core_loop.sh sets after it started the API, and one at a time:
// a workspace has one helper, and issuing a helper's token ends the last one.
@Suite(
    "End to end",
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment[EnvironmentKeys.e2e] == "1"))
struct LeverageEndToEnd {}

extension LeverageEndToEnd {
    /// L868, L893, L894: two seats the app started finish a task end to end
    /// through one failed review. CL-26: the reviewer fails round 0 naming
    /// the second criterion and passes round 1.
    @Suite("The core loop")
    struct CoreLoopEndToEndTests {
        @Test("a builder and a reviewer the helper started take a task to Done through one failed review")
        func coreLoop() async throws {
            let folder = try TestFolder("core-loop")
            let tools = try StandIns.copy(into: folder.url)
            try tools.write(scenario: StandInScenario(reviews: [.init(fail: [2], notes: "Not yet."), .init()]))
            let work = try folder.folder("work")
            let owner = try await EndToEnd.owner()
            // RT-2: the loop with no rule in the way; the second class on the
            // same owner finds them off and changes nothing.
            try await owner.turnShippedRulesOff()
            try folder.record(secrets: [
                EndToEnd.ownerPassword, owner.transport.token ?? "",
                StandIns.statusEmail, StandIns.statusOrganisation,
            ].filter { !$0.isEmpty })

            guard let helperToken = try await owner.issueHelperToken(
                name: "End-to-end Mac", idempotencyKey: IdempotencyKey().value) else {
                throw EndToEndFailure("issue_helper_token answered no token")
            }
            try folder.record(secrets: [helperToken])
            let follower = try await EventFollower.fromNow(owner: owner)
            let helper = try RunningHelper(token: helperToken, folder: folder, tools: tools)

            try await withCleanup {
                // Add credential: each stand-in starts signed out; the helper
                // starts its sign-in, which signs it in, and goes on by itself.
                #expect(!tools.isSignedIn("claude") && !tools.isSignedIn("codex"))
                let claude = try await owner.addLogin(.claude, name: "Claude (end to end)")
                let codex = try await owner.addLogin(.codex, name: "Codex (end to end)")
                let calls = try tools.calls()
                for tool in ["claude", "codex"] {
                    #expect(
                        calls.contains { $0.tool == tool && $0.argv.contains("login") },
                        "the helper started \(tool)'s own sign-in")
                }

                let builder = try await owner.connect("Builder", role: .builder, login: claude)
                let reviewer = try await owner.connect("Reviewer", role: .reviewer, login: codex)
                try await owner.waitUntilRunning([builder, reviewer])

                let added = try await owner.addReadyTask(
                    title: "End-to-end core loop",
                    criteria: ["criterion-1.txt exists.", "criterion-2.txt exists."], folder: work)
                let task = added.task
                _ = try await follower.wait(
                    for: "task.done", deadline: 120,
                    failing: { $0.taskID == task && $0.type == .taskCancelled },
                    where: { $0.taskID == task && $0.type == .taskDone })

                // The task follows trace 09. AP-40 adds one builder cost
                // report after each tool run, between start and pass.
                let events = await follower.events(of: task)
                let expected = try Trace09.commands().flatMap { command -> [[String]] in
                    if command.command == CommandName.startCriterion.rawValue {
                        return [command.events, [EventType.costReported.rawValue]]
                    }
                    return [command.events]
                }
                #expect(events.map(\.type.rawValue) == expected.flatMap { $0 })
                let groups = groupedByCommand(events)
                #expect(groups.map { $0.events.map(\.type.rawValue) } == expected)
                let builderCosts = events.filter { $0.type == .costReported && $0.actorID == builder }
                #expect(builderCosts.count == 3)
                #expect(builderCosts.allSatisfy { $0.payload["spend"]?.numberValue == 0 })
                #expect(groups.allSatisfy { $0.key != nil }, "every event names its command")
                #expect(Set(groups.compactMap(\.key)).count == groups.count, "one key per command")
                #expect(groups.first?.key == added.addKey.value)
                #expect(groups.dropFirst().first?.key == added.contractKey.value)
                #expect(events.filter { $0.type == .reviewFailed }.count == 1)
                #expect(events.filter { $0.type == .reviewPassed }.count == 1)
                let builderEvents = events.filter { [.taskClaimed, .taskSubmitted].contains($0.type) }
                #expect(builderEvents.allSatisfy { $0.actorID == builder })
                let verdicts = events.filter { [.reviewFailed, .reviewPassed].contains($0.type) }
                #expect(verdicts.allSatisfy { $0.actorID == reviewer })
                for name in ["criterion-1.txt", "criterion-2.txt"] {
                    #expect(FileManager.default.fileExists(atPath: work.appendingPathComponent(name).path))
                }

                // Stopping both seats ends both runs and everything they started.
                let runs = try await Processes.startedBy(helper.process.processID, orNaming: folder.url)
                #expect(runs.count >= 2, "the two runs were running: \(runs)")
                try await owner.stopAndWait(seat: builder)
                try await owner.stopAndWait(seat: reviewer)
                try await eventually("every process the runs started ended", deadline: 30) {
                    try await Processes.startedBy(helper.process.processID, orNaming: folder.url).isEmpty
                }
            } cleanup: {
                await helper.stop()
            }
        }
    }

    /// L912: a reviewer stopped while it holds a review loses it, and
    /// another reviewer claims the review and passes it. The review is held
    /// open by the stand-in's gate file, not by timing (PV-7).
    @Suite("A stopped reviewer")
    struct StoppedReviewerEndToEndTests {
        @Test("a stopped reviewer releases its review and a second reviewer passes it")
        func stoppedReviewer() async throws {
            let folder = try TestFolder("stopped-reviewer")
            let tools = try StandIns.copy(into: folder.url)
            try tools.write(scenario: StandInScenario(reviews: [.init()], gateFile: "gate"))
            let work = try folder.folder("work")
            let owner = try await EndToEnd.owner()
            // RT-2: the loop with no rule in the way; the second class on the
            // same owner finds them off and changes nothing.
            try await owner.turnShippedRulesOff()
            try folder.record(secrets: [
                EndToEnd.ownerPassword, owner.transport.token ?? "",
                StandIns.statusEmail, StandIns.statusOrganisation,
            ].filter { !$0.isEmpty })

            guard let helperToken = try await owner.issueHelperToken(
                name: "End-to-end Mac", idempotencyKey: IdempotencyKey().value) else {
                throw EndToEndFailure("issue_helper_token answered no token")
            }
            try folder.record(secrets: [helperToken])
            let follower = try await EventFollower.fromNow(owner: owner)
            let helper = try RunningHelper(token: helperToken, folder: folder, tools: tools)

            try await withCleanup {
                let claude = try await owner.addLogin(.claude, name: "Claude (stopped reviewer)")
                let codex = try await owner.addLogin(.codex, name: "Codex (stopped reviewer)")
                let builder = try await owner.connect("Builder", role: .builder, login: claude)
                let first = try await owner.connect("First reviewer", role: .reviewer, login: codex)
                try await owner.waitUntilRunning([builder, first])

                let task = try await owner.addReadyTask(
                    title: "End-to-end stopped reviewer", criteria: ["criterion-1.txt exists."], folder: work).task
                let notDone: @Sendable (EventRecord) -> Bool = {
                    $0.taskID == task && [.taskCancelled, .taskDone].contains($0.type)
                }
                let started = try await follower.wait(
                    for: "the first review.started", deadline: 120, failing: notDone,
                    where: { $0.taskID == task && $0.type == .reviewStarted })
                #expect(started.actorID == first)

                try await owner.stopAndWait(seat: first)
                let released = try await follower.wait(
                    for: "review.released", deadline: 60, failing: notDone,
                    where: { $0.taskID == task && $0.type == .reviewReleased })
                #expect(released.actorID == first)

                let second = try await owner.connect("Second reviewer", role: .reviewer, login: codex)
                let again = try await follower.wait(
                    for: "the second review.started", deadline: 120, failing: notDone,
                    where: { $0.taskID == task && $0.type == .reviewStarted && $0.seq > released.seq })
                #expect(again.actorID == second)

                try tools.openGate("gate")
                let passed = try await follower.wait(
                    for: "review.passed", deadline: 120,
                    failing: { $0.taskID == task && $0.type == .taskCancelled },
                    where: { $0.taskID == task && $0.type == .reviewPassed })
                #expect(passed.actorID == second)
                _ = try await follower.wait(
                    for: "task.done", deadline: 60, where: { $0.taskID == task && $0.type == .taskDone })
                let events = await follower.events(of: task)
                #expect(!events.contains { $0.type == .reviewFailed })

                try await owner.stopAndWait(seat: builder)
                try await owner.stopAndWait(seat: second)
                try await eventually("every process the runs started ended", deadline: 30) {
                    try await Processes.startedBy(helper.process.processID, orNaming: folder.url).isEmpty
                }
            } cleanup: {
                await helper.stop()
            }
        }
    }
}
