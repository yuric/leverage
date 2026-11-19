import Foundation
import LeverageKit
import LeverageTestSupport
import Testing

@testable import LeverageRunner

// The builder against FakeAgentAPI: trace 09's builder calls in order, the
// rework of the reopened criterion only, and what a tool's answer does.
@Suite("Builder flow", .timeLimit(.minutes(1)))
struct BuilderFlowTests {
    let taskID = UUID()
    let copyID = UUID()
    let layoutID = UUID()
    let reviewCriterionID = UUID()

    func criteria(copy: CriterionState = .open, layout: CriterionState = .open) -> [Criterion] {
        [
            Fixture.criterion(taskID, 1, "The copy names this year's prices.", state: copy, id: copyID),
            Fixture.criterion(taskID, 2, "The layout matches the rest of the site.", state: layout, id: layoutID),
            Fixture.criterion(taskID, 3, "An independent reviewer agrees.", kind: .review, id: reviewCriterionID),
        ]
    }

    func scriptCommands(_ harness: Harness) {
        harness.api.script {
            $0.acknowledgeTaskBriefing = { _, _, _ in Fixture.done(.acknowledgeBriefing) }
            $0.startCriterion = { _, _, _ in Fixture.done(.startCriterion) }
            $0.passCriterion = { _, _, _, _ in Fixture.done(.passCriterion) }
            $0.submitTask = { _, _, _ in Fixture.done(.submit) }
            $0.releaseTask = { _, _, _ in Fixture.done(.release) }
            $0.heartbeatTask = { _, _ in Fixture.beat() }
        }
    }

    @Test("a builder walks trace 09's builder calls in order, then reworks only the reopened criterion")
    func traceNine() async throws {
        let harness = try Harness()
        let driver = ScriptedDriver.agreeable()
        let loop = harness.loop(.builder, driver: driver)
        let reference = harness.existingWork.path
        let taskID = self.taskID
        let claim = Fixture.claim(taskID, criteria: criteria(), workReference: reference, hash: "hash-round-0")
        let reworkBriefing = BriefingResponse(
            briefing: Fixture.briefing(hash: "hash-round-1", criteria: criteria(copy: .passed)),
            workReference: reference,
            reviewNotes: [ReviewNote(reviewID: UUID(), round: 0, notes: "The second criterion does not hold yet.")])
        scriptCommands(harness)
        harness.api.script {
            $0.claimNextTask = { _ in .completed(claim, key: "k", command: .claim) }
            $0.taskBriefing = { _ in reworkBriefing }
        }
        harness.next([NextItem(kind: .task), NextItem(kind: .rework, id: taskID.contractString)], then: loop)

        let code = await runToEnd(loop)

        #expect(code == 0)
        let copy = copyID.contractString, layout = layoutID.contractString
        let expected: [(ContractOperation, String?)] = [
            (.getNext, nil), (.claimNextTask, nil), (.acknowledgeTaskBriefing, nil),
            (.startCriterion, copy), (.passCriterion, copy), (.startCriterion, layout), (.passCriterion, layout),
            (.submitTask, nil),
            (.getNext, nil), (.getTaskBriefing, nil), (.acknowledgeTaskBriefing, nil),
            (.startCriterion, layout), (.passCriterion, layout), (.submitTask, nil),
            (.getNext, nil),
        ]
        let calls = harness.api.calls
        #expect(calls.map(\.operation) == expected.map(\.0))
        #expect(calls.map(\.cid) == expected.map(\.1))
        // Every command has a key of its own.
        let keys = calls.compactMap(\.key)
        #expect(keys.count == 11)
        #expect(Set(keys).count == keys.count)
        // Each acknowledgement carries the briefing it read.
        let acks = harness.calls(.acknowledgeTaskBriefing).map { $0.body?["briefing_hash"]?.stringValue }
        #expect(acks == ["hash-round-0", "hash-round-1"])
        // The review criterion is never built; the builder ran the tool once
        // per open criterion.
        #expect(driver.runs.map(\.purpose) == [.build, .build, .build])
        #expect(driver.runs.allSatisfy { $0.folder.path == reference })
        // The rework's prompt names the reopened criterion first and gives
        // the reviewer's notes.
        let rework = driver.runs[2].prompt
        #expect(rework.range(of: "criterion 2")!.lowerBound < rework.range(of: "criterion 1")?.lowerBound
                ?? rework.endIndex)
        #expect(rework.contains("The second criterion does not hold yet."))
        // Evidence and submission.
        let evidence = harness.calls(.passCriterion).first?.body?["evidence"]
        #expect(evidence?["kind"]?.stringValue == "note")
        #expect(evidence?["value"]?.stringValue == "proof.txt in the work folder")
        for submit in harness.calls(.submitTask) {
            #expect(submit.body?["work_reference"]?.stringValue == reference)
            let note = submit.body?["handoff_note"]?.stringValue ?? ""
            #expect(!note.isEmpty)
        }
        #expect(harness.calls(.releaseTask).isEmpty)
    }

    @Test("an https evidence line is sent as a link")
    func linkEvidence() async throws {
        let harness = try Harness()
        let driver = ScriptedDriver { _, _ in .answer("LEVERAGE-EVIDENCE: https://example.test/pr/1", tokens: 1) }
        let loop = harness.loop(.builder, driver: driver)
        let claim = Fixture.claim(
            taskID, criteria: [criteria()[0]], workReference: harness.existingWork.path)
        scriptCommands(harness)
        harness.api.script { $0.claimNextTask = { _ in .completed(claim, key: "k", command: .claim) } }
        harness.next([NextItem(kind: .task)], then: loop)

        #expect(await runToEnd(loop) == 0)
        let evidence = harness.calls(.passCriterion).first?.body?["evidence"]
        #expect(evidence?["kind"]?.stringValue == "link")
        #expect(evidence?["value"]?.stringValue == "https://example.test/pr/1")
    }

    @Test("an empty work reference makes <work root>/<task id> and submits that path")
    func emptyReference() async throws {
        let harness = try Harness()
        let driver = ScriptedDriver.agreeable()
        let loop = harness.loop(.builder, driver: driver)
        let claim = Fixture.claim(taskID, criteria: [criteria()[0]], workReference: nil)
        scriptCommands(harness)
        harness.api.script { $0.claimNextTask = { _ in .completed(claim, key: "k", command: .claim) } }
        harness.next([NextItem(kind: .task)], then: loop)

        #expect(await runToEnd(loop) == 0)
        let made = harness.workRoot.appendingPathComponent(taskID.contractString).path
        var isFolder: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: made, isDirectory: &isFolder) && isFolder.boolValue)
        #expect(driver.runs.first?.folder.path == made)
        #expect(harness.calls(.submitTask).first?.body?["work_reference"]?.stringValue == made)
    }

    @Test(
        "a work reference that is not an existing local folder is released as unable to continue",
        arguments: ["https://github.com/example/repo", "relative/folder", "/no/such/folder/anywhere"])
    func unusableReference(reference: String) async throws {
        let harness = try Harness()
        let driver = ScriptedDriver.agreeable()
        let loop = harness.loop(.builder, driver: driver)
        let claim = Fixture.claim(taskID, criteria: criteria(), workReference: reference)
        scriptCommands(harness)
        harness.api.script { $0.claimNextTask = { _ in .completed(claim, key: "k", command: .claim) } }
        harness.next([NextItem(kind: .task)], then: loop)

        #expect(await runToEnd(loop) == 0)
        #expect(driver.runs.isEmpty)
        #expect(harness.operations == [.getNext, .claimNextTask, .releaseTask, .getNext])
        #expect(harness.calls(.releaseTask).first?.body?["reason"]?.stringValue == "unable_to_continue")
    }

    @Test(
        "a tool answer with LEVERAGE-CANNOT, no marker line, or a failed run is a release (CL-22)",
        arguments: [
            ScriptedDriver.Step.answer("LEVERAGE-CANNOT: the price list is missing", tokens: 1),
            .answer("I changed some files.", tokens: 1),
            .fail(.exited(1)),
            .fail(.timedOut),
        ])
    func toolFailure(step: ScriptedDriver.Step) async throws {
        let harness = try Harness()
        let driver = ScriptedDriver { _, _ in step }
        let loop = harness.loop(.builder, driver: driver)
        let claim = Fixture.claim(taskID, criteria: criteria(), workReference: harness.existingWork.path)
        scriptCommands(harness)
        harness.api.script { $0.claimNextTask = { _ in .completed(claim, key: "k", command: .claim) } }
        harness.next([NextItem(kind: .task)], then: loop)

        #expect(await runToEnd(loop) == 0)
        #expect(harness.operations == [
            .getNext, .claimNextTask, .acknowledgeTaskBriefing, .startCriterion, .releaseTask, .getNext,
        ])
        #expect(harness.calls(.releaseTask).first?.body?["reason"]?.stringValue == "unable_to_continue")
        #expect(harness.calls(.passCriterion).isEmpty)
    }

    @Test("a refused claim goes back to asking what is next")
    func refusedClaim() async throws {
        let harness = try Harness()
        let loop = harness.loop(.builder, driver: ScriptedDriver.agreeable())
        harness.api.script {
            $0.claimNextTask = { _ in
                .refused(Refusal(code: .notEligible, ruleID: nil, reason: nil), key: "k", command: .claim)
            }
        }
        harness.next([NextItem(kind: .task), NextItem(kind: .none)], then: loop)

        #expect(await runToEnd(loop) == 0)
        #expect(harness.operations == [.getNext, .claimNextTask, .getNext, .getNext])
    }

    @Test("a task claimed after a failed review is built with that review's notes (PRD L127, L493)")
    func claimAfterFailedReview() async throws {
        let harness = try Harness()
        let driver = ScriptedDriver.agreeable()
        let loop = harness.loop(.builder, driver: driver)
        let reference = harness.existingWork.path
        let taskID = self.taskID
        let base = Fixture.claim(taskID, criteria: criteria(copy: .passed), workReference: reference, hash: "hash-round-1")
        let claim = TaskClaim(
            task: TaskSummary(
                id: taskID, title: "Update the pricing page", goal: "The page shows this year's prices.",
                state: .working, round: 1, holderSeatID: Fixture.seatID, builderSeatID: Fixture.seatID,
                workReference: reference),
            lease: base.lease, briefing: base.briefing, workReference: reference, credentialID: base.credentialID,
            model: nil)
        let withNotes = BriefingResponse(
            briefing: base.briefing, workReference: reference,
            reviewNotes: [ReviewNote(reviewID: UUID(), round: 0, notes: "The layout still breaks on narrow screens.")])
        scriptCommands(harness)
        harness.api.script {
            $0.claimNextTask = { _ in .completed(claim, key: "k", command: .claim) }
            $0.taskBriefing = { _ in withNotes }
        }
        harness.next([NextItem(kind: .task)], then: loop)

        let code = await runToEnd(loop)

        #expect(code == 0)
        #expect(harness.api.calls.map(\.operation).contains(.getTaskBriefing))
        let prompt = try #require(driver.runs.first?.prompt)
        #expect(prompt.contains("The layout still breaks on narrow screens."))
    }
}
