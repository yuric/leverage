import LeverageKit
import Testing
@testable import LeverageMCP

struct HeldWorkTests {
    @Test func claimAndAcknowledgeIdentifyTheLeaseAndOnlyItsReleaseClearsIt() {
        var held = HeldWork()
        held.observe(ToolRequest(operation: .claimNextTask),
                     response: ToolResponse(status: 202, body: .object(["outcome": .string("pending")])))
        #expect(held.item == nil)
        held.observe(ToolRequest(operation: .claimNextTask), response: claim(taskID))
        #expect(held.item == .task(taskID))
        held.observe(ToolRequest(operation: .acknowledgeTaskBriefing, path: ["id": taskID]), response: completed())
        #expect(held.item == .task(taskID))
        held.observe(ToolRequest(operation: .heartbeatTask, path: ["id": otherTaskID]), response: refused(.notHolder))
        #expect(held.item == .task(taskID))
        held.observe(ToolRequest(operation: .releaseTask, path: ["id": taskID]), response: completed())
        #expect(held.item == nil)
        held.observe(ToolRequest(operation: .claimNextReview), response: claim(reviewID, kind: "review"))
        #expect(held.item == .review(reviewID))
        held.observe(ToolRequest(operation: .giveVerdict, path: ["id": reviewID]), response: completed())
        #expect(held.item == nil)
    }

    @Test(arguments: [RefusalCode.notHolder, .leaseExpired, .taskCancelled, .invalidState])
    func aRefusedCallClearsMatchingWork(code: RefusalCode) {
        var held = HeldWork()
        held.observe(ToolRequest(operation: .claimNextTask), response: claim(taskID))
        held.observe(ToolRequest(operation: .startAction, path: ["id": taskID, "aid": actionID]),
                     response: completed())
        #expect(held.hasStartedAction(task: taskID, action: actionID))
        held.observe(ToolRequest(operation: .heartbeatTask, path: ["id": taskID]), response: refused(code))
        #expect(held.item == nil)
        #expect(!held.hasStartedAction(task: taskID, action: actionID))
    }

    @Test func completedPendingClaimIsLearnedAndPendingSubmitDoesNotDropTheLease() throws {
        var held = HeldWork()
        let claimKey = try #require(IdempotencyKey("fixture-pending-claim"))
        let submitKey = try #require(IdempotencyKey("fixture-pending-submit"))
        let pending = ToolResponse(status: 202, body: .object(["outcome": .string("pending")]))
        held.observe(ToolRequest(operation: .claimNextTask, key: claimKey), response: pending)
        #expect(held.item == nil)
        let claimPoll = ToolRequest(operation: .getCommand, path: ["key": claimKey.value])
        held.observe(claimPoll, response: claim(taskID))
        #expect(held.item == .task(taskID))
        held.observe(ToolRequest(operation: .submitTask, path: ["id": taskID], key: submitKey), response: pending)
        #expect(held.item == .task(taskID))
        held.observe(ToolRequest(operation: .getCommand, path: ["key": submitKey.value]), response: completed())
        #expect(held.item == nil)
        held.observe(claimPoll, response: claim(taskID))
        #expect(held.item == nil)
    }

    @Test func newBriefingReplacesThePreviouslyReadActionStates() {
        var held = HeldWork()
        let request = ToolRequest(operation: .getTaskBriefing, path: ["id": taskID])
        held.observe(request, response: briefing(actionState: "started"))
        #expect(held.hasStartedAction(task: taskID, action: actionID))
        #expect(!held.hasStartedAction(task: otherTaskID, action: actionID))
        held.observe(request, response: briefing(actionState: "approved"))
        #expect(!held.hasStartedAction(task: taskID, action: actionID))
    }

    @Test func eachAnnouncedCriterionIsRememberedUntilItPasses() {
        var held = HeldWork()
        let first = ToolRequest(operation: .startCriterion, path: ["id": taskID, "cid": criterionID])
        held.observe(first, response: completed())
        #expect(held.hasStartedCriterion(task: taskID, criterion: criterionID))
        let second = ToolRequest(operation: .startCriterion, path: ["id": taskID, "cid": actionID])
        held.observe(second, response: completed())
        #expect(held.hasStartedCriterion(task: taskID, criterion: actionID))
        #expect(held.hasStartedCriterion(task: taskID, criterion: criterionID))
        held.observe(ToolRequest(operation: .passCriterion, path: second.path), response: completed())
        #expect(!held.hasStartedCriterion(task: taskID, criterion: actionID))
    }
}
