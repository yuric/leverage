import Foundation
import LeverageKit
import LeverageTestSupport
import Testing

// The Handoff milestone's acceptance run (milestone 3 plan §5.2; PRD L871):
// the first sign-in to the first Done, with a run interrupted in each of the
// three forms. scripts/e2e_handoff.sh runs each test alone, on a compose
// project and database of its own, with `LEVERAGE_E2E=handoff`. Every test
// adds the reviewer's login first, so it stands above the builder's and is
// never one of the builder's candidates; no test interrupts the reviewer.
// Reset times are near (L732) and are data only: the stand-ins' directives
// count prompts (HD-11).

private let criteria = ["criterion-1.txt exists.", "criterion-2.txt exists."]
private let claudeModel = HandoffWorld.defaultModel(.claude)

/// The events of the whole log, oldest first.
private func wholeLog(_ world: HandoffWorld) async -> [EventRecord] {
    await world.follower.seen.sorted { $0.seq < $1.seq }
}

private func firstPassed(_ events: [EventRecord], task: UUID) throws -> EventRecord {
    try #require(events.first { $0.taskID == task && $0.type == .criterionPassed }, "criterion 1 passed")
}

/// Form A: a limit after work is saved, handed over at once (L725, L901,
/// L902).
@Suite("A limit after work is saved: handed over", .serialized, .enabled(if: handoffEnabled))
struct LimitHandoffEndToEndTests {
    @Test("a limit on the builder's login hands the task to the next login of the same provider (L901)")
    func testSameProvider() async throws {
        try await withHandoffWorld("limit-same-provider") { world in
            let reviewerLogin = UUID(), one = UUID(), two = UUID()
            try world.tools.write(scenario: StandInScenario(reviews: [.init()], directives: [
                .reply("claude/run-limit-five-hour.json", tool: "claude", account: world.accountFolder(one),
                       onPrompt: 2, resetInSeconds: 3600, times: 1),
            ]))
            _ = try await world.addLogin(.codex, name: "Reviewer", id: reviewerLogin)
            _ = try await world.addLogin(.claude, name: "One", id: one)
            _ = try await world.addLogin(.claude, name: "Two", id: two)
            let builder = try await world.owner.connect("Builder", role: .builder, login: one)
            let reviewer = try await world.owner.connect("Reviewer", role: .reviewer, login: reviewerLogin)
            try await world.owner.waitUntilRunning([builder, reviewer])

            let task = try await world.owner.addReadyTask(
                title: "Limit, same provider", criteria: criteria, folder: world.work).task
            _ = try await world.waitForDone(task)
            let log = await wholeLog(world)
            try inOrder(log, after: try firstPassed(log, task: task).seq, [
                .type(.credentialLimitReached) { $0.subjectID == one && $0.id("seat_id") == builder },
                // Within the seat's provider the run keeps the seat's model
                // (HE-5): none here, the tool's own default.
                .type(.credentialSwitched) {
                    $0.subjectID == two && $0.id("from_credential_id") == one && $0.id("seat_id") == builder
                        && $0.payload["model"] == .null
                },
                .type(.criterionStarted) { $0.taskID == task },
                .type(.criterionPassed) { $0.taskID == task },
                .type(.taskSubmitted) { $0.taskID == task },
                .type(.reviewPassed) { $0.taskID == task },
                .type(.taskDone) { $0.taskID == task },
            ])
            #expect(log.filter { $0.type == .credentialLimitReached }.count == 1)
            try await checkHandoff(world, task: task, builder: builder, recoveries: [.handedOff])
            try await world.stopSeats([builder, reviewer])
        }
    }

    @Test("a limit on the builder's login hands the task to a login of another provider, with its model (L902)")
    func testOtherProvider() async throws {
        try await withHandoffWorld("limit-other-provider") { world in
            let reviewerLogin = UUID(), team = UUID(), one = UUID()
            try world.tools.write(scenario: StandInScenario(reviews: [.init()], directives: [
                .reply("codex/run-limit-five-hour.json", tool: "codex", account: world.accountFolder(team),
                       onPrompt: 2, resetInSeconds: 3600, times: 1),
            ]))
            _ = try await world.addLogin(.codex, name: "Reviewer", id: reviewerLogin)
            _ = try await world.addLogin(.codex, name: "Team", id: team)
            _ = try await world.addLogin(.claude, name: "One", id: one)
            let stored = try await world.owner.credentials().credentials.first { $0.credential.id == one }
            #expect(stored?.credential.model == claudeModel, "One keeps the model Add credential sent")
            let builder = try await world.owner.connect("Builder", role: .builder, login: team)
            let reviewer = try await world.owner.connect("Reviewer", role: .reviewer, login: reviewerLogin)
            try await world.owner.waitUntilRunning([builder, reviewer])

            let task = try await world.owner.addReadyTask(
                title: "Limit, other provider", criteria: criteria, folder: world.work).task
            _ = try await world.waitForDone(task)
            let log = await wholeLog(world)
            try inOrder(log, after: try firstPassed(log, task: task).seq, [
                .type(.credentialLimitReached) { $0.subjectID == team && $0.id("seat_id") == builder },
                .type(.credentialSwitched) {
                    $0.subjectID == one && $0.id("from_credential_id") == team && $0.string("model") == claudeModel
                },
                .type(.criterionStarted) { $0.taskID == task },
                .type(.criterionPassed) { $0.taskID == task },
                .type(.taskSubmitted) { $0.taskID == task },
                .type(.reviewPassed) { $0.taskID == task },
                .type(.taskDone) { $0.taskID == task },
            ])
            // The second run is the Claude stand-in, started with One's model.
            let oneFolder = world.accountFolder(one).resolvingSymlinksInPath().path
            let claudeWork = try world.tools.calls().filter { call in
                call.tool == "claude"
                    && call.env["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
                        == oneFolder
                    && call.argv.contains { $0.contains("LEVERAGE-") }
            }
            #expect(!claudeWork.isEmpty, "the builder went on with the Claude stand-in on One")
            if let model = claudeModel {
                #expect(claudeWork.allSatisfy { $0.argv.contains(model) }, "each run names One's model")
            }
            try await checkHandoff(world, task: task, builder: builder, recoveries: [.handedOff])
            try await world.stopSeats([builder, reviewer])
        }
    }
}

/// Form A, the wait: no other login, so the task waits for the reset, which
/// the sweep releases (L726, first half).
@Suite("A limit after work is saved: the wait", .serialized, .enabled(if: handoffEnabled))
struct LimitWaitEndToEndTests {
    @Test("a limit with no other login holds the task until the reset, then the same login goes on (L726)")
    func testWaitsForTheReset() async throws {
        try await withHandoffWorld("limit-wait") { world in
            let reviewerLogin = UUID(), one = UUID()
            let resetIn = 30
            try world.tools.write(scenario: StandInScenario(reviews: [.init()], directives: [
                .reply("claude/run-limit-five-hour.json", tool: "claude", account: world.accountFolder(one),
                       onPrompt: 2, resetInSeconds: resetIn, times: 1),
            ]))
            _ = try await world.addLogin(.codex, name: "Reviewer", id: reviewerLogin)
            _ = try await world.addLogin(.claude, name: "One", id: one)
            let builder = try await world.owner.connect("Builder", role: .builder, login: one)
            let reviewer = try await world.owner.connect("Reviewer", role: .reviewer, login: reviewerLogin)
            try await world.owner.waitUntilRunning([builder, reviewer])

            let task = try await world.owner.addReadyTask(
                title: "Limit, the wait", criteria: criteria, folder: world.work).task
            let held = try await world.follower.wait(
                for: "the credential_limit hold", deadline: 120,
                failing: { $0.taskID == task && $0.type == .taskCancelled },
                where: { $0.taskID == task && $0.type == .holdOpened })
            #expect(held.string("reason") == HoldReason.credentialLimit.rawValue)
            #expect(held.id("credential_id") == one)

            // While it waits: no Needs you item, and the card names One and
            // the time it resets (HM-40). The reset comes resetIn seconds
            // after the stand-in's reply, long enough for the board to be
            // read while the hold is open. A hold already closed after the
            // board was read means the card was read after the reset, and
            // is a failure, never a check passed over (second review).
            let card = try await world.owner.board().tasks.first { $0.task.id == task }
            let stillHeld = try await world.owner.task(id: task).holds.contains {
                $0.id == held.subjectID && $0.closedAt == nil
            }
            #expect(stillHeld, """
                the hold closed before the board was read, \(resetIn) s after the reply: \
                the card was not read while it waited
                """)
            #expect(card?.waitingForCredentialID == one, "the card names the login it waits for")
            #expect(card?.waitingUntil != nil, "the card names the time")
            let items = try await world.owner.listInbox(afterSeq: nil, wait: nil).items
            #expect(!items.contains { $0.aboutID == task || $0.credentialID == one }, "no Needs you item: \(items)")

            _ = try await world.waitForDone(task)
            let log = await wholeLog(world)
            try inOrder(log, after: try firstPassed(log, task: task).seq, [
                .type(.credentialLimitReached) { $0.subjectID == one && $0.id("seat_id") == builder },
                .type(.holdOpened) { $0.taskID == task && $0.string("reason") == "credential_limit" },
                .type(.holdClosed) { $0.taskID == task && $0.string("reason") == "credential_limit" },
                .type(.criterionStarted) { $0.taskID == task },
                .type(.criterionPassed) { $0.taskID == task },
                .type(.taskDone) { $0.taskID == task },
            ])
            #expect(!log.contains { $0.type == .credentialSwitched }, "the same login went on")
            #expect(!log.contains { $0.type == .inboxOpened })
            #expect(log.filter { $0.type == .credentialLimitReached }.count == 1)
            try await checkHandoff(world, task: task, builder: builder, recoveries: [.waited])
            try await world.stopSeats([builder, reviewer])
        }
    }
}

/// Form B: a login found signed out (L727, L903).
@Suite("A login found signed out", .serialized, .enabled(if: handoffEnabled))
struct SignedOutEndToEndTests {
    @Test("a signed-out login hands the task to the next login (L903, first half)")
    func testHandsOff() async throws {
        try await withHandoffWorld("signed-out-hands-off") { world in
            let reviewerLogin = UUID(), one = UUID(), two = UUID()
            try world.tools.write(scenario: StandInScenario(reviews: [.init()], directives: [
                .signOut(tool: "claude", account: world.accountFolder(one), beforePrompt: 2),
            ]))
            _ = try await world.addLogin(.codex, name: "Reviewer", id: reviewerLogin)
            _ = try await world.addLogin(.claude, name: "One", id: one)
            _ = try await world.addLogin(.claude, name: "Two", id: two)
            let builder = try await world.owner.connect("Builder", role: .builder, login: one)
            let reviewer = try await world.owner.connect("Reviewer", role: .reviewer, login: reviewerLogin)
            try await world.owner.waitUntilRunning([builder, reviewer])

            let task = try await world.owner.addReadyTask(
                title: "Signed out, handed over", criteria: criteria, folder: world.work).task
            _ = try await world.waitForDone(task)
            let log = await wholeLog(world)
            try inOrder(log, after: try firstPassed(log, task: task).seq, [
                .type(.credentialSignedOut) { $0.subjectID == one && $0.id("seat_id") == builder },
                .type(.credentialSwitched) { $0.subjectID == two && $0.id("from_credential_id") == one },
                .type(.criterionStarted) { $0.taskID == task },
                .type(.criterionPassed) { $0.taskID == task },
                .type(.taskDone) { $0.taskID == task },
            ])
            #expect(!log.contains { $0.type == .inboxOpened })
            try await checkHandoff(world, task: task, builder: builder, recoveries: [.handedOff])
            try await world.stopSeats([builder, reviewer])
        }
    }

    @Test("a signed-out login with no other login holds the task until Sign in again (L903, second half)")
    func testHeldUntilSignIn() async throws {
        try await withHandoffWorld("signed-out-held") { world in
            let reviewerLogin = UUID(), one = UUID()
            try world.tools.write(scenario: StandInScenario(reviews: [.init()], directives: [
                .signOut(tool: "claude", account: world.accountFolder(one), beforePrompt: 2),
            ]))
            _ = try await world.addLogin(.codex, name: "Reviewer", id: reviewerLogin)
            _ = try await world.addLogin(.claude, name: "One", id: one)
            let builder = try await world.owner.connect("Builder", role: .builder, login: one)
            let reviewer = try await world.owner.connect("Reviewer", role: .reviewer, login: reviewerLogin)
            try await world.owner.waitUntilRunning([builder, reviewer])
            let before = await wholeLog(world).last?.seq ?? 0

            let task = try await world.owner.addReadyTask(
                title: "Signed out, held", criteria: criteria, folder: world.work).task
            // What the notification is posted from: the long poll of the
            // inbox from a cursor returns the item (HM-28, HM-29).
            let item = try await nextInboxItem(world, after: before) { $0.kind == .accountSignedOut }
            #expect(item.credentialID == one)
            #expect(item.choices.contains { $0.rawValue == "sign_in_again" })
            #expect(world.tools.isSignedIn("claude", accountFolder: world.accountFolder(one)) == false)

            _ = try await world.owner.followed(
                "Sign in again", try await world.owner.signInAgain(credentialID: one, key: IdempotencyKey()))
            _ = try await world.waitForDone(task)
            let log = await wholeLog(world)
            try inOrder(log, after: try firstPassed(log, task: task).seq, [
                .type(.credentialSignedOut) { $0.subjectID == one && $0.id("seat_id") == builder },
                .type(.holdOpened) { $0.taskID == task && $0.string("reason") == "credential_signed_out" },
                .type(.inboxOpened) { $0.string("kind") == "account_signed_out" },
                .type(.credentialVerified) { $0.subjectID == one },
                .type(.holdClosed) { $0.taskID == task && $0.string("reason") == "credential_signed_out" },
                .type(.inboxResolved) { $0.string("choice") == "sign_in_again" },
                .type(.criterionStarted) { $0.taskID == task },
                .type(.criterionPassed) { $0.taskID == task },
                .type(.taskDone) { $0.taskID == task },
            ])
            try await checkHandoff(world, task: task, builder: builder, recoveries: [.waited])
            try await world.stopSeats([builder, reviewer])
        }
    }
}

/// Form C: one account at its limit while the next is signed out (L904).
@Suite("A limit while the next login is signed out", .serialized, .enabled(if: handoffEnabled))
struct LimitThenSignedOutEndToEndTests {
    @Test("a limit while the next login is signed out holds the task until Sign in again on that login (L904)")
    func testHeldUntilTheNextSignsIn() async throws {
        try await withHandoffWorld("limit-then-signed-out") { world in
            let reviewerLogin = UUID(), one = UUID(), two = UUID()
            try world.tools.write(scenario: StandInScenario(reviews: [.init()], directives: [
                .reply("claude/run-limit-five-hour.json", tool: "claude", account: world.accountFolder(one),
                       onPrompt: 2, resetInSeconds: 3600, times: 1),
            ]))
            _ = try await world.addLogin(.codex, name: "Reviewer", id: reviewerLogin)
            _ = try await world.addLogin(.claude, name: "One", id: one)
            _ = try await world.addLogin(.claude, name: "Two", id: two)

            // Two is signed out in its own tool, and Verify finds it so.
            try world.signOutInTool("claude", account: world.accountFolder(two))
            let verify = try await world.owner.followed(
                "Verify of Two", try await world.owner.verifyCredential(credentialID: two, key: IdempotencyKey()),
                expected: .failed)
            #expect(verify.result?.checks.contains { $0.check == .signedIn && $0.failure == .notSignedIn } == true)
            let signedOut = try await world.follower.wait(
                for: "Two's credential.signed_out", deadline: 60,
                where: { $0.type == .credentialSignedOut && $0.subjectID == two })
            #expect(signedOut.id("seat_id") == nil, "Verify's sign-out names no seat")

            let builder = try await world.owner.connect("Builder", role: .builder, login: one)
            let reviewer = try await world.owner.connect("Reviewer", role: .reviewer, login: reviewerLogin)
            try await world.owner.waitUntilRunning([builder, reviewer])
            let before = await wholeLog(world).last?.seq ?? 0

            let task = try await world.owner.addReadyTask(
                title: "Limit, next signed out", criteria: criteria, folder: world.work).task
            let item = try await nextInboxItem(world, after: before) { $0.kind == .accountSignedOut }
            #expect(item.credentialID == two, "the item names Two")

            _ = try await world.owner.followed(
                "Sign in again on Two",
                try await world.owner.signInAgain(credentialID: two, key: IdempotencyKey()))
            _ = try await world.waitForDone(task)
            let log = await wholeLog(world)
            try inOrder(log, after: try firstPassed(log, task: task).seq, [
                .type(.credentialLimitReached) { $0.subjectID == one && $0.id("seat_id") == builder },
                .type(.holdOpened) {
                    $0.taskID == task && $0.string("reason") == "credential_signed_out" && $0.id("credential_id") == two
                },
                .type(.inboxOpened) { $0.string("kind") == "account_signed_out" },
                .type(.credentialVerified) { $0.subjectID == two },
                .type(.holdClosed) { $0.taskID == task && $0.string("reason") == "credential_signed_out" },
                .type(.credentialSwitched) { $0.subjectID == two && $0.id("from_credential_id") == one },
                .type(.inboxResolved) { $0.string("choice") == "sign_in_again" },
                .type(.criterionStarted) { $0.taskID == task },
                .type(.criterionPassed) { $0.taskID == task },
                .type(.taskDone) { $0.taskID == task },
            ])
            try await checkHandoff(world, task: task, builder: builder, recoveries: [.waited])
            try await world.stopSeats([builder, reviewer])
        }
    }
}

/// Long-polls the inbox from `after` (`list_inbox` with `after_seq` and
/// `wait`) until an item that matches opens.
private func nextInboxItem(
    _ world: HandoffWorld, after: Int, deadline seconds: Double = 120, _ matches: (InboxItem) -> Bool
) async throws -> InboxItem {
    let deadline = Date().addingTimeInterval(seconds)
    var cursor = after
    while true {
        let left = deadline.timeIntervalSinceNow
        guard left > 0 else { throw EndToEndFailure("no Needs you item opened within \(Int(seconds)) s") }
        let page = try await world.owner.listInbox(afterSeq: cursor, wait: min(20, max(1, Int(left))))
        if let item = page.items.first(where: matches) { return item }
        cursor = page.nextAfterSeq
    }
}
