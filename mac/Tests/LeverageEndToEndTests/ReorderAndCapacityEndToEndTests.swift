import Foundation
import LeverageKit
import LeverageTestSupport
import Testing

/// CR-14 and CR-30, through the real helper, runner and sweep.
@Suite("Capacity and the handoff order", .serialized, .enabled(if: credentialsEnabled))
struct ReorderAndCapacityEndToEndTests {
    private let deadline = Patience.seconds(120)
    private let criteria = ["criterion-1.txt exists.", "criterion-2.txt exists."]

    @Test("a reading or Verify ends one wait and reordering ends the next")
    func testWaitsEnd() async throws {
        let harness = try await CredentialsHarness.start(name: "reorder-and-capacity")
        try await withCleanup {
            try await run(harness.handoffWorld)
        } cleanup: {
            await harness.stop()
        }
    }

    private func run(_ world: HandoffWorld) async throws {
        let reviewerLogin = UUID(), one = UUID(), two = UUID()
        let provider: Provider = Provider.codex.testedToolVersions.isEmpty ? .claude : .codex
        let reviewerProvider: Provider = provider == .codex ? .claude : .codex
        let tool = provider.rawValue
        let account = world.accountFolder(one)
        let version = provider.testedToolVersions.first
        let capacityFixtures = try version.map { _ in try CapacityFixtures(tools: world.tools, provider: provider) }
        var scenario = StandInScenario(reviews: [.init()], directives: [
            .reply("\(tool)/run-limit-five-hour-no-reset.json", tool: tool, account: account, onPrompt: 2, times: 1),
            // One answers three prompts in task 1. Task 2 meets its limit
            // on the second prompt of that task, the fifth on One.
            .reply("\(tool)/run-limit-five-hour.json", tool: tool, account: account,
                   onPrompt: 5, resetInSeconds: 3600, times: 1),
        ])
        if let version, let capacityFixtures {
            // Locate asks for the version without the account's environment.
            scenario.usage = [
                .init(tool: tool, version: version),
                .init(tool: tool, account: account, reply: capacityFixtures.full, version: version),
                .init(tool: tool, account: world.accountFolder(two), version: version),
            ]
        }
        try world.tools.write(scenario: scenario)
        for (login, name, kind) in [(reviewerLogin, "Reviewer", reviewerProvider),
                                    (one, "One", provider), (two, "Two", provider)] {
            _ = try await world.owner.addLogin(
                kind, name: name, id: login, model: HandoffWorld.defaultModel(kind), strengthRank: 1, deadline: deadline)
        }
        let before = try await world.owner.credentials()
        #expect(before.credentials.map(\.credential.id) == [reviewerLogin, one, two])
        try await reorder(world, order: [reviewerLogin, two, one], key: IdempotencyKey())
        if capacityFixtures != nil {
            // Drain the first reads before starting work. A Refresh after
            // the limit must start a fresh observation, not reuse Add's.
            try await refresh(world, credentials: [reviewerLogin, one, two])
        }

        let builder = try await world.owner.connect("Builder", role: .builder, login: one)
        let reviewer = try await world.owner.connect("Reviewer", role: .reviewer, login: reviewerLogin)
        let untimed = try await world.owner.addReadyTask(
            title: "Limit with no reset time", criteria: criteria, folder: world.work).task
        let firstHold = try await hold(world, task: untimed)
        let opened = try await world.follower.wait(for: "the limit Needs you item", deadline: deadline) {
            $0.taskID == untimed && $0.type == .inboxOpened
        }
        let firstLog = await world.follower.events(of: untimed)
        let firstLimit = try #require(firstLog.first { event in event.type == .credentialLimitReached })
        #expect(firstLimit.subjectID == one && firstLimit.id("seat_id") == builder)
        #expect(firstLimit.string("window") == LimitWindow.fiveHour.rawValue)
        #expect(firstLimit.payload["reset_at"] == .null)
        #expect(firstLimit.seq < firstHold.seq && firstHold.seq < opened.seq)
        #expect(firstHold.id("credential_id") == one)
        #expect(opened.string("kind") == NeedsYouItem.limitWithNoResetTime.rawValue)
        #expect(firstLimit.commandID == firstHold.commandID && firstHold.commandID == opened.commandID)

        var verifyEvent: EventRecord?
        if let capacityFixtures {
            try await refresh(world, credentials: [reviewerLogin, one, two])
            try await expectReading(world, account: one, percent: 100, after: firstLimit)
            let stillHeld = try await world.owner.task(id: untimed)
            #expect(stillHeld.holds.contains { $0.id == firstHold.subjectID && $0.closedAt == nil })
            #expect(stillHeld.inboxItems.contains { $0.id == opened.subjectID && $0.state == .open })

            try setUsageReply(capacityFixtures.room, account: account, scenario: &scenario)
            try world.tools.write(scenario: scenario)
            try await refresh(world, credentials: [reviewerLogin, one, two])
            try await expectReading(world, account: one, percent: 40, after: firstLimit)
        } else {
            _ = try await world.owner.followed(
                "Verify One", try await world.owner.verifyCredential(credentialID: one, key: IdempotencyKey()),
                deadline: deadline)
            verifyEvent = try await world.follower.wait(for: "One verified", deadline: deadline) {
                $0.type == .credentialVerified && $0.subjectID == one && $0.seq > opened.seq
            }
        }

        _ = try await world.waitForDone(untimed, deadline: deadline)
        let firstEnd = await world.follower.seen
        let closing = try inOrder(firstEnd, after: verifyEvent?.seq ?? opened.seq, [
            .type(.holdClosed) { $0.taskID == untimed && $0.subjectID == firstHold.subjectID },
            .type(.inboxResolved) { $0.taskID == untimed && $0.subjectID == opened.subjectID },
        ])
        // Either a helper reading or the helper's Verify result ends this
        // wait. The latter also writes credential.verified in its command.
        let close = try #require(closing.first)
        let closeKey = try #require(close.commandID)
        #expect(close.actorKind == .app && close.actorID == firstLimit.actorID)
        let closeEvents = firstEnd.filter { $0.commandID == closeKey }
        #expect(closeEvents.map(\.type) == (verifyEvent == nil
            ? [.holdClosed, .inboxResolved] : [.credentialVerified, .holdClosed, .inboxResolved]))
        if let verifyEvent { #expect(closeKey == verifyEvent.commandID) }
        try await checkHandoff(world, task: untimed, builder: builder, recoveries: [.waited])

        if let capacityFixtures {
            try setUsageReply(capacityFixtures.full, account: account, scenario: &scenario)
            try world.tools.write(scenario: scenario)
        }
        let timedWork = try world.folder.folder("work-with-reset")
        let timed = try await world.owner.addReadyTask(
            title: "Limit with a reset time", criteria: criteria, folder: timedWork).task
        let secondHold = try await hold(world, task: timed)
        let secondLog = await world.follower.events(of: timed)
        let secondLimit = try #require(secondLog.first { event in event.type == .credentialLimitReached })
        #expect(secondLimit.subjectID == one && secondLimit.id("seat_id") == builder)
        #expect(secondLimit.seq < secondHold.seq && secondLimit.commandID == secondHold.commandID)
        #expect(secondLimit.string("window") == LimitWindow.fiveHour.rawValue)
        #expect(secondLimit.string("reset_at") != nil)
        let waiting = try await world.owner.task(id: timed)
        #expect(waiting.waitingForCredentialID == one && waiting.waitingUntil != nil)
        #expect(waiting.inboxItems.isEmpty)

        let reorderKey = IdempotencyKey()
        try await reorder(world, order: [reviewerLogin, one, two], key: reorderKey)
        _ = try await world.waitForDone(timed, deadline: deadline)
        let end = await world.follower.seen
        let changes = end.filter { $0.commandID == reorderKey.value }
        #expect(changes.map(\.type) == [.credentialOrderChanged, .credentialOrderChanged, .holdClosed, .credentialSwitched])
        #expect(changes.map(\.subjectID) == [one, two, secondHold.subjectID, two])
        let switched = try #require(changes.last)
        #expect(switched.taskID == timed && switched.id("from_credential_id") == one && switched.id("seat_id") == builder)
        #expect(!end.contains { $0.taskID == timed && $0.type == .inboxOpened })
        try await checkHandoff(world, task: timed, builder: builder, recoveries: [.waited])
        for seat in [builder, reviewer] { try await world.owner.stopAndWait(seat: seat) }
    }

    private func setUsageReply(_ reply: String, account: URL, scenario: inout StandInScenario) throws {
        let index = try #require(scenario.usage.firstIndex { $0.account == account.path })
        scenario.usage[index].reply = reply
    }

    private func reorder(_ world: HandoffWorld, order: [UUID], key: IdempotencyKey) async throws {
        _ = try await world.owner.reorderCredentials(.init(order: order), key: key).completedResult()
        let list = try await world.owner.credentials()
        try #require(list.credentials.map(\.credential.id) == order)
    }

    private func hold(_ world: HandoffWorld, task: UUID) async throws -> EventRecord {
        try await world.follower.wait(
            for: "the credential limit hold", deadline: deadline,
            failing: { $0.taskID == task && [.taskCancelled, .taskDone].contains($0.type) },
            where: {
                $0.taskID == task && $0.type == .holdOpened
                    && $0.string("reason") == HoldReason.credentialLimit.rawValue
            })
    }

    private func refresh(_ world: HandoffWorld, credentials: [UUID]) async throws {
        let outcome = try await world.owner.refreshUsage(key: IdempotencyKey())
        let result = try outcome.completedResult()
        let queued = try #require(result)
        var read: [UUID] = []
        for id in queued.helperRequestIDs {
            let request = try await finishedRequest(id, owner: world.owner, deadline: deadline)
            try #require(request.kind == .readUsage && request.state == .finished)
            read.append(try #require(request.credentialID))
        }
        #expect(read.count == credentials.count && Set(read) == Set(credentials))
    }

    private func expectReading(_ world: HandoffWorld, account: UUID, percent: Double, after: EventRecord) async throws {
        let list = try await world.owner.credentials()
        let row = try #require(list.credentials.first { $0.credential.id == account })
        let reading = try #require(row.reading)
        #expect(reading.state == .ok && reading.observedAt > after.at)
        #expect(reading.figures.first { $0.kind == .limit && $0.window == .fiveHour }?.percentUsed == percent)
        #expect((row.credential.limitedSince != nil) == (percent == 100))
    }
}

/// Copies the documented Codex reply shape from the made-up fixture and
/// changes just its 5-hour percentage. Both copies stay inside this
/// test's stand-in folder, so another test retains the original figures.
private struct CapacityFixtures {
    let full: String
    let room: String

    init(tools: StandInTools, provider: Provider) throws {
        guard provider == .codex else {
            throw EndToEndFailure("the enabled provider has no 5-hour capacity fixture")
        }
        full = try Self.writeCodex(100, tools: tools)
        room = try Self.writeCodex(40, tools: tools)
    }

    private static func writeCodex(_ percent: Int, tools: StandInTools) throws -> String {
        let source = tools.replies.appendingPathComponent("codex/usage-both-windows.json")
        let original = try Data(contentsOf: source)
        guard var fixture = try JSONSerialization.jsonObject(with: original) as? [String: Any],
              var session = fixture["session"] as? [String: Any],
              var reply = session["account/rateLimits/read"] as? [String: Any],
              var result = reply["result"] as? [String: Any],
              var limits = result["rateLimits"] as? [String: Any],
              var primary = limits["primary"] as? [String: Any],
              primary["windowDurationMins"] as? Int == 300 else {
            throw EndToEndFailure("the Codex fixture has no primary 5-hour window")
        }
        primary["usedPercent"] = percent
        limits["primary"] = primary
        result["rateLimits"] = limits
        reply["result"] = result
        session["account/rateLimits/read"] = reply
        fixture["session"] = session
        let file = "codex/usage-capacity-\(percent).json"
        let data = try JSONSerialization.data(withJSONObject: fixture, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: tools.replies.appendingPathComponent(file), options: .atomic)
        return file
    }
}
