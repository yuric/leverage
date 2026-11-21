import Foundation
import LeverageKit
import LeverageTestSupport
import Testing

// The Rule checks milestone's acceptance run, part one (milestone 4 plan
// §5.2): the shipped rules as they ship, and a custom rule at "before work is
// submitted". scripts/e2e_rule_checks.sh runs each test alone, on a compose
// project and database of its own, with `LEVERAGE_E2E=rule_checks`. The
// logins are stand-ins: Claude "One" for the builder, Codex "Team" for the
// reviewer and Gemini "Studio" for the orchestrator.

/// The shipped rules by key (`shipped_rules.json`).
private let acceptanceCriteria = "acceptance_criteria"
private let specificDetails = "specific_details"
private let acceptanceSentence = "Every task needs acceptance criteria"

extension EventRecord {
    func isCheck(_ type: EventType, rule: UUID, result: String? = nil) -> Bool {
        self.type == type && id("rule_id") == rule && (result == nil || string("result") == result)
    }
}

/// The custom rule both submit tests add, its instruction holding a marker.
private func addSubmitRule(_ world: RuleChecksWorld) async throws -> UUID {
    let name = "Submitted work is checked"
    _ = try await world.owner.addRule(
        AddRuleRequest(
            name: name, instruction: "Pass the work only when its folder names \(world.markers[1]).",
            hook: .taskBeforeSubmit, scope: RuleScope(kind: .allTasks)),
        key: IdempotencyKey()).completedResult()
    let row = try #require(
        try await world.owner.listRules().rules.first { $0.version.origin == .custom && $0.version.name == name },
        "the custom rule is listed")
    #expect(row.rule.enabled && row.version.hook == .taskBeforeSubmit && row.version.checker == .model)
    return row.rule.id
}

@Suite("The shipped rules", .serialized, .enabled(if: ruleChecksEnabled))
struct ShippedRulesEndToEndTests {
    /// L896, L897: form to Done through agents the app started, with the
    /// shipped rules on and an orchestrator among the agents.
    @Test("a task goes from the form to Done with the shipped rules on and an orchestrator checking it")
    func testFormToDone() async throws {
        try await withRuleChecksWorld("form-to-done") { world in
            let agents = try await world.usualAgents()
            let criteria = try await world.shippedRule(acceptanceCriteria).rule.id
            let details = try await world.shippedRule(specificDetails).rule.id

            let added = try await world.addTask(title: "Form to Done \(world.markers[0])")
            #expect(added.contract.outcome == .pending, "Complete contract waits for the model check")
            let task = added.task
            _ = try await world.waitForDone(task)

            let events = await world.follower.events(of: task)
            let found = try inOrder(events, [
                .type(.taskCreated) { $0.commandID == added.addKey.value },
                Expected("check.finished (acceptance criteria, passed)") {
                    $0.isCheck(.checkFinished, rule: criteria, result: "passed")
                        && $0.commandID == added.contractKey.value
                },
                Expected("check.queued (specific details)") {
                    $0.isCheck(.checkQueued, rule: details) && $0.commandID == added.contractKey.value
                },
                .type(.jobQueued) { $0.commandID == added.contractKey.value && $0.string("kind") == "rule_check" },
                .type(.jobClaimed) {
                    $0.actorID == agents.orchestrator && $0.id("credential_id") == agents.orchestratorLogin
                },
                .type(.checkStarted) { $0.actorID == agents.orchestrator },
                .type(.jobFinished) { $0.actorID == agents.orchestrator },
                Expected("check.finished (specific details, passed)") {
                    $0.isCheck(.checkFinished, rule: details, result: "passed")
                },
                .type(.costReported) { $0.actorID == agents.orchestrator },
                .type(.taskContractChanged) { $0.commandID == added.contractKey.value && $0.actorKind == .owner },
                .type(.taskReady) { $0.commandID == added.contractKey.value && $0.actorKind == .owner },
                .type(.taskClaimed) { $0.actorID == agents.builder },
                .type(.criterionPassed) { $0.actorID == agents.builder },
                .type(.taskSubmitted) { $0.actorID == agents.builder },
                .type(.reviewStarted) { $0.actorID == agents.reviewer },
                .type(.reviewPassed) { $0.actorID == agents.reviewer },
                .type(.taskDone),
            ])
            // The later events of Complete contract name the check that let
            // it through as their cause.
            let passed = found[7]
            #expect(found[9].causeID == passed.id && found[10].causeID == passed.id)

            // The builder's claim answer carries the rules that act, which
            // the runner hands its tool as quoted material.
            let build = try world.prompts("claude", containing: "LEVERAGE-EVIDENCE")
            #expect(!build.isEmpty, "the builder's tool was run")
            #expect(build.allSatisfy { $0.contains(acceptanceSentence) }, "the acceptance sentence is in the briefing")
            #expect(build.allSatisfy { !$0.contains("Workers ask the orchestrator before they ask you") })

            // One attempt with a queue time and a run time; steps that sum
            // to the lifetime.
            let page = try await world.owner.task(id: task)
            let rows = page.ruleChecks.filter { $0.ruleID == details }
            let row = try #require(rows.first)
            #expect(rows.count == 1 && row.result == .passed)
            #expect(row.attempts.count == 1)
            #expect(row.queueSeconds != nil && row.runSeconds != nil)
            let sum = page.steps.reduce(0) { $0 + $1.seconds }
            #expect(abs(sum - page.lifetimeSeconds) <= 1, "steps \(sum) s, lifetime \(page.lifetimeSeconds) s")

            try checkKeysAndCauses(await world.wholeLog())
            try await world.stopSeats(agents.all)
        }
    }

    /// L801: a task whose details the orchestrator finds vague stays in
    /// Backlog with its reason on the card, until the owner completes the
    /// contract again.
    @Test("a vague task stays in Backlog with the checker's reason until its contract is completed again")
    func testVagueTaskStaysInBacklog() async throws {
        try await withRuleChecksWorld("vague-task", markerCount: 3) { world in
            try world.write(RuleChecksScenario(checkFailWhenContains: world.markers[1]))
            let agents = try await world.usualAgents()
            let details = try await world.shippedRule(specificDetails).rule.id
            let title = "Vague task \(world.markers[0])"

            let added = try await world.addTask(
                title: title, details: "The run's details name \(world.markers[0]) and \(world.markers[1]).")
            #expect(added.contract.outcome == .pending)
            let task = added.task
            let held = try await world.waitFor("hold.opened (contract_incomplete)", task: task) {
                $0.taskID == task && $0.type == .holdOpened && $0.string("reason") == "contract_incomplete"
            }
            var events = await world.follower.events(of: task)
            let first = try inOrder(events, [
                Expected("check.queued (specific details)") { $0.isCheck(.checkQueued, rule: details) },
                .type(.jobClaimed) { $0.actorID == agents.orchestrator },
                Expected("check.finished (failed)") { $0.isCheck(.checkFinished, rule: details, result: "failed") },
                .type(.taskContractChanged) { $0.commandID == added.contractKey.value },
                .type(.holdOpened) { $0.seq == held.seq && $0.commandID == added.contractKey.value },
            ])
            #expect(!events.contains { $0.type == .taskReady })

            // The card says why.
            let card = try #require(try await world.owner.board().tasks.first { $0.task.id == task })
            #expect(card.task.state == .backlog)
            #expect(card.holdReasons.contains(.contractIncomplete))
            #expect(card.checkReason == world.checkerReason)

            // The owner completes the contract again with other details.
            let again = try await world.completeContract(
                task, title: title, details: "Other details name \(world.markers[0]).")
            #expect(again.outcome.outcome == .pending)
            _ = try await world.waitForDone(task)
            events = await world.follower.events(of: task)
            let second = try inOrder(events, after: held.seq, [
                .type(.holdClosed) { $0.commandID == again.key.value && $0.string("reason") == "contract_incomplete" },
                Expected("a second check.queued") {
                    $0.isCheck(.checkQueued, rule: details) && $0.commandID == again.key.value
                },
                Expected("check.finished (passed)") { $0.isCheck(.checkFinished, rule: details, result: "passed") },
                .type(.taskReady) { $0.commandID == again.key.value },
                .type(.taskDone),
            ])
            #expect(second[1].string("input_hash") != first[0].string("input_hash"), "the second check is on a new hash")

            try checkKeysAndCauses(await world.wholeLog())
            try await world.stopSeats(agents.all)
        }
    }
}

@Suite("A rule at before work is submitted", .serialized, .enabled(if: ruleChecksEnabled))
struct SubmitRuleEndToEndTests {
    /// L908: a model-checked rule blocks a submit; the reason reaches the
    /// builder; the attempts show their queue and run times.
    @Test("a custom rule refuses the first submit with its reason, and the reworked submit passes")
    func testRuleBlocksSubmitThenPasses() async throws {
        try await withRuleChecksWorld("submit-rule", markerCount: 3) { world in
            // The details, then the submit's two checks.
            try world.write(RuleChecksScenario(checkVerdicts: ["PASSED", "FAILED", "PASSED"]))
            let rule = try await addSubmitRule(world)
            let agents = try await world.usualAgents()
            let added = try await world.addTask(title: "Submit rule \(world.markers[0])")
            let task = added.task
            _ = try await world.waitForDone(task)

            let events = await world.follower.events(of: task)
            let found = try inOrder(events, [
                .type(.taskReady),
                Expected("the first submit's check.queued") {
                    $0.isCheck(.checkQueued, rule: rule) && $0.actorID == agents.builder
                },
                Expected("check.finished (failed)") { $0.isCheck(.checkFinished, rule: rule, result: "failed") },
                Expected("the second submit's check.queued") {
                    $0.isCheck(.checkQueued, rule: rule) && $0.actorID == agents.builder
                },
                Expected("check.finished (passed)") { $0.isCheck(.checkFinished, rule: rule, result: "passed") },
                .type(.taskSubmitted) { $0.actorID == agents.builder },
                .type(.reviewPassed),
                .type(.taskDone),
            ])
            let (firstKey, secondKey) = (found[1].commandID, found[3].commandID)
            #expect(firstKey != nil && secondKey != nil && firstKey != secondKey, "the second submit has a new key")
            #expect(found[1].string("input_hash") != found[3].string("input_hash"), "and another hash")
            #expect(found[5].commandID == secondKey && found[5].causeID == found[4].id)
            #expect(!events.contains { $0.type == .taskSubmitted && $0.commandID == firstKey })
            #expect(events.filter { $0.type == .taskSubmitted }.count == 1)

            // The builder's tool ran again, with the reason quoted and
            // nowhere else in its prompt.
            let reworks = try world.prompts("claude", containing: "sent back by a check")
            let rework = try #require(reworks.first)
            #expect(reworks.count == 1)
            let lines = rework.split(separator: "\n", omittingEmptySubsequences: false)
            let holding = lines.filter { $0.contains(world.checkerReason) }
            #expect(!holding.isEmpty, "the reason reached the builder")
            #expect(holding.allSatisfy { $0.hasPrefix("> ") }, "only inside a quote block")

            // Two check rows for the rule, each attempt with its times.
            let page = try await world.owner.task(id: task)
            let rows = page.ruleChecks.filter { $0.ruleID == rule }
            #expect(rows.count == 2)
            #expect(rows.compactMap(\.result).sorted { $0.rawValue < $1.rawValue } == [.failed, .passed])
            #expect(rows.first { $0.result == .failed }?.reason == world.checkerReason)
            for attempt in rows.flatMap(\.attempts) {
                #expect(attempt.startedAt != nil && attempt.finishedAt != nil, "queued, started and finished")
            }

            try checkKeysAndCauses(await world.wholeLog())
            try await world.stopSeats(agents.all)
        }
    }

    /// L422, L910: the fourth try at a check that keeps failing waits for
    /// the owner, who lets it through once with a reason.
    @Test("the fourth try waits for the owner, who lets it through once")
    func testFourthTryWaitsForTheOwner() async throws {
        try await withRuleChecksWorld("fourth-try", markerCount: 4) { world in
            try world.write(RuleChecksScenario(checkVerdicts: ["PASSED"] + Array(repeating: "FAILED", count: 8)))
            let rule = try await addSubmitRule(world)
            let agents = try await world.usualAgents()
            let added = try await world.addTask(title: "Fourth try \(world.markers[0])")
            let task = added.task

            let held = try await world.waitFor("hold.opened (rerun_limit)", deadline: 180, task: task) {
                $0.taskID == task && $0.type == .holdOpened && $0.string("reason") == "rerun_limit"
            }
            let opened = try await world.waitFor("inbox.opened (check_past_rerun_limit)", task: task) {
                $0.taskID == task && $0.type == .inboxOpened && $0.string("kind") == "check_past_rerun_limit"
            }
            var events = await world.follower.events(of: task)
            let refused = events.filter { $0.isCheck(.checkFinished, rule: rule, result: "failed") }
            #expect(refused.count == 3, "three refused submits")
            #expect(refused.allSatisfy { $0.seq < held.seq })
            #expect(!events.contains { $0.type == .taskSubmitted })

            let item = try #require(
                try await world.owner.listInbox(afterSeq: nil, wait: nil).items.first {
                    $0.kind == .checkPastRerunLimit && $0.aboutID == task && $0.state == .open
                }, "the item is open")
            #expect(item.choices.count == 3, "its three choices: \(item.choices)")

            let check = try #require(held.id("rule_check_id"), "the hold names its check")
            let reason = "Let it through for \(world.markers[2])."
            _ = try await world.owner.overrideCheck(
                checkID: check, OverrideCheckRequest(reason: reason), key: IdempotencyKey()).completedResult()
            _ = try await world.waitForDone(task)
            events = await world.follower.events(of: task)
            try inOrder(events, after: opened.seq, [
                .type(.checkOverridden) { $0.subjectID == check },
                .type(.holdClosed) { $0.string("reason") == "rerun_limit" },
                .type(.inboxResolved),
                .type(.taskSubmitted) { $0.commandID == held.commandID && $0.actorID == agents.builder },
                .type(.taskDone),
            ])

            // Who, when and why.
            let page = try await world.owner.task(id: task)
            let row = try #require(page.ruleChecks.first { $0.id == check })
            #expect(row.overriddenAt != nil && row.overriddenByUserID != nil)
            #expect(row.overrideReason == reason)

            try checkKeysAndCauses(await world.wholeLog())
            try await world.stopSeats(agents.all)
        }
    }
}
