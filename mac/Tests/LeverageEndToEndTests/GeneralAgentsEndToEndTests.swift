import Foundation
import LeverageKit
import LeverageTestSupport
import Testing

@Suite("Two General agents", .enabled(if: ruleChecksEnabled))
struct GeneralAgentsEndToEndTests {
    @Test("two General agents take a task from the form to Done with the shipped rules on")
    func testTwoGeneralAgentsFormToDone() async throws {
        try await withRuleChecksWorld("two-general-agents") { world in
            let claude = try await world.addLogin(.claude, name: "One")
            let codex = try await world.addLogin(.codex, name: "Team")
            let one = try await world.owner.connect("General One", role: .general, login: claude)
            let two = try await world.owner.connect("General Two", role: .general, login: codex)
            let seats: Set<UUID> = [one, two]
            try await world.owner.waitUntilRunning([one, two])
            try await eventually("both General agents polled", deadline: Patience.seconds(60)) {
                let polled = try await world.owner.seats().seats.filter { $0.role == .general && $0.lastPolledAt != nil }
                return Set(polled.map(\.id)) == seats
            }

            let shipped = try await world.owner.listRules().rules.filter { $0.version.origin == .shipped }
            #expect(shipped.count == 7 && shipped.allSatisfy { $0.rule.enabled })
            let details = try await world.shippedRule("specific_details").rule.id
            let added = try await world.addTask(title: "General agents \(world.markers[0])")
            try #require(added.contract.outcome == .pending)
            let task = added.task
            _ = try await world.waitForDone(task, deadline: Patience.seconds(60))

            let events = await world.follower.events(of: task)
            let checked = try #require(events.first { $0.type == .jobClaimed }?.actorID)
            let builder = try #require(events.first { $0.type == .taskClaimed }?.actorID)
            let reviewer = try #require(events.first { $0.type == .reviewStarted }?.actorID)
            #expect(seats.contains(checked))
            #expect(Set([builder, reviewer]) == seats)
            try inOrder(events, [
                .type(.taskCreated) { $0.commandID == added.addKey.value },
                .type(.jobQueued) { $0.commandID == added.contractKey.value && $0.string("kind") == "rule_check" },
                .type(.jobClaimed) { $0.actorID == checked },
                .type(.jobFinished) { $0.actorID == checked },
                Expected("the General agent's check passed") {
                    $0.isCheck(.checkFinished, rule: details, result: "passed") && $0.actorID == checked
                },
                .type(.taskReady) { $0.commandID == added.contractKey.value },
                .type(.taskClaimed) { $0.actorID == builder },
                .type(.taskBriefingAcknowledged) { $0.actorID == builder },
                .type(.criterionPassed) { $0.actorID == builder },
                .type(.taskSubmitted) { $0.actorID == builder },
                .type(.reviewStarted) { $0.actorID == reviewer },
                .type(.reviewPassed) { $0.actorID == reviewer },
                .type(.taskDone),
            ])

            let tool = checked == one ? "claude" : "codex"
            let checkPrompts = try world.prompts(tool, containing: "LEVERAGE-VERDICT-")
            let hasGeneralRules = checkPrompts.count == 1
                && SeatRole.general.jobRules.allSatisfy { checkPrompts[0].contains($0) }
            #expect(hasGeneralRules, "the runner gave the stand-in the General job rules")
            #expect(try await world.owner.task(id: task).task.state == .done)
            try checkKeysAndCauses(await world.wholeLog())
            try await world.stopSeats([one, two])
        }
    }
}
