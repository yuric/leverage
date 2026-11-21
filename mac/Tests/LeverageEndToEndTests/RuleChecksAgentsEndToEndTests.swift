import Foundation
import LeverageKit
import LeverageTestSupport
import Testing

// The Rule checks milestone's acceptance run, part two (milestone 4 plan
// §5.2): the orchestrator offline and back, the provider rule at review, and
// a contract a planner drafts. Run as RuleChecksEndToEndTests.swift says.

/// The orchestrator's seat and its last-polled time, from `list_seats`.
private func lastPolled(_ world: RuleChecksWorld, _ seat: UUID) async throws -> Date? {
    try await world.owner.seats().seats.first { $0.id == seat }?.lastPolledAt
}

@Suite("The orchestrator offline", .serialized, .enabled(if: ruleChecksEnabled))
struct OrchestratorOfflineEndToEndTests {
    /// L909: stopping the orchestrator the app runs opens one workspace item
    /// within 120 seconds of its last poll; starting it again queues the
    /// waiting checks without a click. The bound is read from the server's
    /// own times, so a slow machine cannot fail it; the wait for the item is
    /// longer only so that one can see it.
    @Test("a stopped orchestrator opens one workspace item, and starting it again lets the check through")
    func testOfflineAndBack() async throws {
        try await withRuleChecksWorld("orchestrator-offline") { world in
            let studio = try await world.addLogin(.gemini, name: "Studio")
            let orchestrator = try await world.owner.connect("Orchestrator", role: .orchestrator, login: studio)
            try await world.owner.waitUntilRunning([orchestrator])
            try await eventually("the orchestrator polled", deadline: ruleCheckDeadline) {
                try await lastPolled(world, orchestrator) != nil
            }
            let details = try await world.shippedRule("specific_details").rule.id

            try await world.owner.stopAndWait(seat: orchestrator)
            let added = try await world.addTask(title: "Offline \(world.markers[0])")
            #expect(added.contract.outcome == .pending)
            let task = added.task

            let opened = try await world.waitFor("inbox.opened (orchestrator_offline)", deadline: 150) {
                $0.type == .inboxOpened && $0.string("kind") == "orchestrator_offline"
            }
            let polled = try #require(try await lastPolled(world, orchestrator), "the seat's last poll is kept")
            let seconds = opened.at.timeIntervalSince(polled)
            #expect(seconds <= 120, "the item opened \(seconds) s after the last poll (L909)")
            #expect(seconds >= 90, "and not before L401's 90 seconds: \(seconds) s")
            #expect(opened.taskID == nil, "it is about the workspace")

            let open = try await world.owner.listInbox(afterSeq: nil, wait: nil).items.filter { $0.state == .open }
            let offline = open.filter { $0.kind == .orchestratorOffline }
            let item = try #require(offline.first)
            #expect(offline.count == 1 && item.aboutKind == .workspace)
            #expect(item.waitingChecks == 1, "the item counts one waiting check")
            #expect(!open.contains { $0.aboutID == task }, "no item about the task")
            var events = await world.follower.events(of: task)
            #expect(!events.contains { $0.type == .inboxOpened })

            // Started again, and nothing else is sent.
            _ = try await world.owner.startSeat(seatID: orchestrator, key: IdempotencyKey()).completedResult()
            let resolved = try await world.waitFor("inbox.resolved", deadline: ruleCheckDeadline) {
                $0.type == .inboxResolved && $0.subjectID == item.id
            }
            _ = try await world.waitFor("task.ready", task: task) { $0.taskID == task && $0.type == .taskReady }
            events = await world.follower.events(of: task)
            try inOrder(events, [
                .type(.jobClaimed) { $0.actorID == orchestrator },
                Expected("check.finished (passed)") { $0.isCheck(.checkFinished, rule: details, result: "passed") },
                .type(.taskReady) { $0.commandID == added.contractKey.value },
            ])
            // Claimed only once the seat ran again. The sweep's timer may
            // resolve the item before or after that first claim: the item
            // closes when the role polls again (L402), not when it claims.
            #expect(events.filter { $0.type == .jobClaimed }.allSatisfy { $0.seq > opened.seq })
            #expect(resolved.seq > opened.seq)
            #expect(await world.wholeLog().filter { $0.type == .inboxOpened && $0.string("kind") == "orchestrator_offline" }.count == 1)

            try checkKeysAndCauses(await world.wholeLog())
            try await world.stopSeats([orchestrator])
        }
    }
}

@Suite("The provider rule", .serialized, .enabled(if: ruleChecksEnabled))
struct ProviderRuleEndToEndTests {
    /// L448, L912: a reviewer of the provider that built the task is never
    /// offered its review, the owner is told nobody may review it, and a
    /// reviewer of another provider takes it to Done.
    @Test("a reviewer of the building provider is never offered the review; one of another provider passes it")
    func testNoReviewerEligibleThenAnother() async throws {
        try await withRuleChecksWorld("provider-rule") { world in
            let one = try await world.addLogin(.claude, name: "One")
            let two = try await world.addLogin(.claude, name: "Two")
            let studio = try await world.addLogin(.gemini, name: "Studio")
            let builder = try await world.owner.connect("Builder", role: .builder, login: one)
            let claudeReviewer = try await world.owner.connect("Claude reviewer", role: .reviewer, login: two)
            let orchestrator = try await world.owner.connect("Orchestrator", role: .orchestrator, login: studio)
            try await world.owner.waitUntilRunning([builder, claudeReviewer, orchestrator])

            let task = try await world.addTask(title: "Provider rule \(world.markers[0])").task
            let submitted = try await world.waitFor("task.submitted", task: task) {
                $0.taskID == task && $0.type == .taskSubmitted
            }
            let opened = try await world.waitFor("inbox.opened (no_reviewer_eligible)", task: task) {
                $0.taskID == task && $0.type == .inboxOpened && $0.string("kind") == "no_reviewer_eligible"
            }
            #expect(opened.commandID == submitted.commandID, "opened at submit")

            // The Claude reviewer keeps polling and is never offered the
            // review: its last-polled time moves twice, and it writes nothing.
            var seen: [Date] = []
            try await eventually("the Claude reviewer's last poll moved twice", deadline: ruleCheckDeadline) {
                if let at = try await lastPolled(world, claudeReviewer), seen.last != at { seen.append(at) }
                return seen.count >= 3
            }
            let log = await world.wholeLog()
            #expect(!log.contains { $0.type == .reviewStarted })
            #expect(!log.contains { $0.actorID == claudeReviewer }, "no command by the Claude reviewer")

            // A reviewer on Codex (the reference runner offers no Gemini
            // reviewer, plan §0.1 fact 27).
            let team = try await world.addLogin(.codex, name: "Team")
            let codexReviewer = try await world.owner.connect("Codex reviewer", role: .reviewer, login: team)
            _ = try await world.waitForDone(task)
            let events = await world.follower.events(of: task)
            try inOrder(events, after: opened.seq, [
                .type(.inboxResolved) { $0.taskID == task },
                .type(.reviewStarted) { $0.actorID == codexReviewer },
                .type(.reviewPassed) { $0.actorID == codexReviewer },
                .type(.taskDone),
            ])
            let started = try #require(events.first { $0.type == .reviewStarted })
            #expect(started.string("credential_id").flatMap(UUID.init(uuidString:)).map { $0 == team } ?? true)
            #expect(!events.contains { $0.actorID == claudeReviewer })

            try checkKeysAndCauses(await world.wholeLog())
            try await world.stopSeats([builder, claudeReviewer, orchestrator, codexReviewer])
        }
    }
}

@Suite("A drafted contract", .serialized, .enabled(if: ruleChecksEnabled))
struct DraftContractEndToEndTests {
    /// L802: Draft the details. A planner writes the contract, the shipped
    /// rules check it, and the task is Ready, its work reference kept.
    @Test("a planner drafts the contract, the checks pass, and the task is Ready")
    func testDraftToReady() async throws {
        try await withRuleChecksWorld("draft-contract") { world in
            let team = try await world.addLogin(.codex, name: "Team")
            let studio = try await world.addLogin(.gemini, name: "Studio")
            let planner = try await world.owner.connect("Planner", role: .planner, login: team)
            let orchestrator = try await world.owner.connect("Orchestrator", role: .orchestrator, login: studio)
            try await world.owner.waitUntilRunning([planner, orchestrator])
            let criteria = try await world.shippedRule("acceptance_criteria").rule.id
            let details = try await world.shippedRule("specific_details").rule.id

            let addKey = IdempotencyKey()
            let added = try await world.owner.addTask(
                AddTaskRequest(
                    title: "Draft \(world.markers[0])", goal: "A page names \(world.markers[1]).",
                    priority: .normal, workReference: world.work.path, state: .backlog),
                key: addKey)
            let task = try #require(try added.completedResult()?.taskID)
            let draftKey = IdempotencyKey()
            _ = try await world.owner.draftContract(taskID: task, key: draftKey).completedResult()
            _ = try await world.waitFor("task.ready", task: task) { $0.taskID == task && $0.type == .taskReady }

            let events = await world.follower.events(of: task)
            let found = try inOrder(events, [
                .type(.jobQueued) { $0.commandID == draftKey.value && $0.string("kind") == "contract_draft" },
                .type(.jobClaimed) { $0.actorID == planner },
                .type(.jobFinished) { $0.actorID == planner },
                .type(.costReported) { $0.actorID == planner },
                Expected("check.finished (acceptance criteria, passed)") {
                    $0.isCheck(.checkFinished, rule: criteria, result: "passed") && $0.actorID == planner
                },
                Expected("check.queued with the planner as requester") {
                    $0.isCheck(.checkQueued, rule: details) && $0.actorID == planner
                },
                .type(.jobClaimed) { $0.actorID == orchestrator },
                Expected("check.finished (specific details, passed)") {
                    $0.isCheck(.checkFinished, rule: details, result: "passed") && $0.actorID == orchestrator
                },
                .type(.taskContractChanged),
                .type(.taskReady),
            ])
            #expect(found[8].commandID == found[5].commandID, "Complete contract under the planner's result's key")

            let page = try await world.owner.task(id: task)
            #expect(page.task.workReference == world.work.path, "the work reference the test gave")
            #expect(page.task.state == .ready)
            #expect(page.steps.map(\.kind) == [.waitContract, .draft, .check, .waitReady])

            try checkKeysAndCauses(await world.wholeLog())
            try await world.stopSeats([planner, orchestrator])
        }
    }
}
