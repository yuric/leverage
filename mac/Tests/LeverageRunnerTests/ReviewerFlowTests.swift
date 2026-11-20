import Foundation
import LeverageKit
import LeverageTestSupport
import Testing

@testable import LeverageRunner

// The reviewer against FakeAgentAPI: claim review, acknowledge, one tool
// run, a verdict naming the failed criteria; a failed run is a release.
@Suite("Reviewer flow", .timeLimit(.minutes(Patience.minutes(1))))
struct ReviewerFlowTests {
    let taskID = UUID()
    let reviewID = UUID()
    let copyID = UUID()
    let layoutID = UUID()

    var criteria: [Criterion] {
        [
            Criterion(
                id: copyID, taskID: taskID, position: 1, text: "The copy names this year's prices.", kind: .build,
                state: .passed,
                evidence: [CriterionEvidence(id: UUID(), criterionID: copyID, kind: .note, value: "copy.txt")]),
            Criterion(
                id: layoutID, taskID: taskID, position: 2, text: "The layout matches the rest of the site.",
                kind: .build, state: .passed,
                evidence: [CriterionEvidence(
                    id: UUID(), criterionID: layoutID, kind: .link, value: "https://example.test/layout")]),
            Fixture.criterion(taskID, 3, "An independent reviewer agrees.", kind: .review),
        ]
    }

    func reviewer(_ harness: Harness, driver: any ToolDriver, timing: RunnerTiming = .fast()) -> RunnerLoop {
        let loop = harness.loop(.reviewer, driver: driver, timing: timing)
        let claim = Fixture.reviewClaim(
            reviewID, taskID: taskID, criteria: criteria, workReference: harness.existingWork.path)
        harness.api.script {
            $0.claimNextReview = { _ in .completed(claim, key: "k", command: .claimReview) }
            $0.acknowledgeReviewBriefing = { _, _, _ in Fixture.done(.acknowledgeReviewBriefing) }
            $0.giveVerdict = { _, _, _ in Fixture.done(.failReview) }
            $0.releaseReview = { _, _ in Fixture.done(.releaseReview) }
            $0.heartbeatReview = { _, _ in
                .completed(HeartbeatResult(leaseDueAt: Date().addingTimeInterval(3600)), key: "k",
                           command: .heartbeatReview)
            }
        }
        return loop
    }

    @Test("a reviewer claims, acknowledges, runs the tool once and fails the criterion it names")
    func failsNamedCriterion() async throws {
        let harness = try Harness()
        let driver = ScriptedDriver { _, _ in
            .answer(
                "LEVERAGE-CRITERION 1: PASS\nLEVERAGE-CRITERION 2: FAIL\n"
                    + "LEVERAGE-NOTES: The second criterion does not hold yet.", tokens: 1200)
        }
        let loop = reviewer(harness, driver: driver)
        harness.next([NextItem(kind: .review)], then: loop)

        #expect(await runToEnd(loop) == 0)
        #expect(harness.operations == [
            .getNext, .claimNextReview, .acknowledgeReviewBriefing, .giveVerdict, .getNext,
        ])
        #expect(harness.calls(.acknowledgeReviewBriefing).first?.body?["briefing_hash"]?.stringValue == "review-0")
        #expect(harness.calls(.acknowledgeReviewBriefing).first?.id == reviewID.contractString)
        let verdict = try #require(harness.calls(.giveVerdict).first?.body)
        #expect(verdict["verdict"]?.stringValue == "failed")
        #expect(verdict["failed_criteria"] == .array([.string(layoutID.contractString)]))
        #expect(verdict["notes"]?.stringValue == "The second criterion does not hold yet.")
        #expect(verdict["tokens"]?.intValue == 1200)
        #expect(verdict["spend"]?.numberValue == 0)
        // One run, read-only, in the work folder, naming both builder
        // criteria and nothing else as a criterion.
        #expect(driver.runs.count == 1)
        #expect(driver.runs[0].purpose == .review)
        #expect(driver.runs[0].folder.path == harness.existingWork.path)
        let prompt = driver.runs[0].prompt
        #expect(prompt.contains("criterion 1") && prompt.contains("criterion 2"))
        #expect(!prompt.contains("criterion 3"))
        #expect(prompt.contains("copy.txt") && prompt.contains("https://example.test/layout"))
    }

    @Test("every criterion passing is a passed verdict with no failed criteria")
    func passes() async throws {
        let harness = try Harness()
        let driver = ScriptedDriver { _, _ in
            .answer("LEVERAGE-CRITERION 1: PASS\nLEVERAGE-CRITERION 2: PASS\nLEVERAGE-NOTES: Every criterion holds.",
                    tokens: 7)
        }
        let loop = reviewer(harness, driver: driver)
        harness.next([NextItem(kind: .review)], then: loop)

        #expect(await runToEnd(loop) == 0)
        let verdict = try #require(harness.calls(.giveVerdict).first?.body)
        #expect(verdict["verdict"]?.stringValue == "passed")
        #expect(verdict["failed_criteria"] == .array([]))
        #expect(verdict["notes"]?.stringValue == "Every criterion holds.")
    }

    @Test(
        "an answer without a verdict for every criterion, or a failed run, releases the review (CL-22)",
        arguments: [
            ScriptedDriver.Step.answer("LEVERAGE-CRITERION 1: PASS\nLEVERAGE-NOTES: Half done.", tokens: 1),
            .answer("It looks fine to me.", tokens: 1),
            .fail(.reportedError),
        ])
    func releases(step: ScriptedDriver.Step) async throws {
        let harness = try Harness()
        let loop = reviewer(harness, driver: ScriptedDriver { _, _ in step })
        harness.next([NextItem(kind: .review)], then: loop)

        #expect(await runToEnd(loop) == 0)
        #expect(harness.operations == [
            .getNext, .claimNextReview, .acknowledgeReviewBriefing, .releaseReview, .getNext,
        ])
    }

    @Test("a stop ends the tool, releases the review and exits 0 (CL-23)")
    func stopReleasesReview() async throws {
        let harness = try Harness()
        let driver = ScriptedDriver { _, _ in .block }
        let loop = reviewer(harness, driver: driver)
        harness.api.script { $0.next = { _ in NextItem(kind: .review) } }
        let run = Task { await runToEnd(loop) }
        #expect(await eventually { driver.runs.count == 1 })
        loop.stop()

        #expect(await run.value == 0)
        #expect(driver.cancelledRuns == 1)
        #expect(harness.calls(.releaseReview).map(\.id) == [reviewID.contractString])
        #expect(harness.calls(.giveVerdict).isEmpty)
    }

    @Test("briefing_changed with the review's id re-reads and acknowledges the review's briefing")
    func briefingChanged() async throws {
        let harness = try Harness()
        let loop = reviewer(harness, driver: ScriptedDriver { _, _ in
            .answer("LEVERAGE-CRITERION 1: PASS\nLEVERAGE-CRITERION 2: PASS\nLEVERAGE-NOTES: Fine.", tokens: 1)
        })
        let changed = BriefingResponse(
            briefing: Fixture.briefing(hash: "review-changed", criteria: criteria),
            workReference: harness.existingWork.path)
        harness.api.script { $0.reviewBriefing = { _ in changed } }
        harness.next(
            [NextItem(kind: .briefingChanged, id: taskID.contractString, reviewID: reviewID)], then: loop)

        #expect(await runToEnd(loop) == 0)
        #expect(harness.operations == [
            .getNext, .getReviewBriefing, .acknowledgeReviewBriefing, .giveVerdict, .getNext,
        ])
        #expect(harness.calls(.acknowledgeReviewBriefing).first?.body?["briefing_hash"]?.stringValue
                == "review-changed")
    }

    @Test("a review whose work reference is not an existing folder is released without a tool run")
    func unusableReference() async throws {
        let harness = try Harness()
        let driver = ScriptedDriver.agreeable()
        let loop = harness.loop(.reviewer, driver: driver)
        let claim = Fixture.reviewClaim(reviewID, taskID: taskID, criteria: criteria, workReference: "/no/such/folder")
        harness.api.script {
            $0.claimNextReview = { _ in .completed(claim, key: "k", command: .claimReview) }
            $0.acknowledgeReviewBriefing = { _, _, _ in Fixture.done(.acknowledgeReviewBriefing) }
            $0.releaseReview = { _, _ in Fixture.done(.releaseReview) }
        }
        harness.next([NextItem(kind: .review)], then: loop)

        #expect(await runToEnd(loop) == 0)
        #expect(driver.runs.isEmpty)
        #expect(harness.calls(.releaseReview).count == 1)
    }

    @Test("a reviewer does not claim tasks")
    func ignoresTasks() async throws {
        let harness = try Harness()
        let loop = harness.loop(.reviewer, driver: ScriptedDriver.agreeable())
        harness.next([NextItem(kind: .task), NextItem(kind: .rework, id: taskID.contractString)], then: loop)

        #expect(await runToEnd(loop) == 0)
        #expect(harness.operations == [.getNext, .getNext, .getNext])
    }
}
