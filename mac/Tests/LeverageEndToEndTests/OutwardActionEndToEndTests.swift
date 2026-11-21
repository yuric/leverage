import Foundation
import LeverageKit
import LeverageTestSupport
import Testing

@Suite(.serialized, .enabled(if: questionsApprovalsEnabled), .timeLimit(.minutes(Patience.minutes(8))))
struct OutwardActionEndToEndTests {
    @Test
    func testApprovedActionReachesDone() async throws {
        try await withQuestionsApprovalsWorld("approved-action", configure: { world in
            var scenario = QuestionsApprovalsScenario()
            scenario.reviewGateFile = world.folder.url.appendingPathComponent("review.go").path
            scenario.actionTouchFile = world.folder.url.appendingPathComponent("published.txt").path
            scenario.approvalDecisions = ["APPROVE"]
            return scenario
        }) { world in
            let builder = try await world.managedBuilder()
            let added = try await addPublishTask(world)
            let task = added.task
            let reviewer = try #require(world.reviewer)
            let review = try await world.waitFor("review.started", task: task) {
                $0.taskID == task && $0.type == .reviewStarted && $0.actorID == reviewer
            }
            let inReview = try await world.owner.task(id: task)
            let action = try publishAction(inReview)
            let refusalKey = IdempotencyKey()
            let refusal = try await world.owner.approveAction(actionID: action.id, key: refusalKey)
            #expect(refusal.outcome == .refused)
            #expect(refusal.refusal?.code == .invalidState)
            let afterRefusal = try await world.owner.task(id: task)
            #expect(afterRefusal.task.state == .inReview)
            #expect(try publishAction(afterRefusal).state == .contracted)
            let refusedWithoutEvents = !afterRefusal.events.contains { $0.commandID == refusalKey.value }
            #expect(refusedWithoutEvents)
            let touchFile = world.folder.url.appendingPathComponent("published.txt")
            #expect(!FileManager.default.fileExists(atPath: touchFile.path))
            try Data().write(to: world.folder.url.appendingPathComponent("review.go"))

            let done = try await world.waitForDone(task)
            let events = await world.follower.events(of: task)
            let addKey = added.addKey.value
            let contractKey = added.contractKey.value
            try questionsApprovalsOrder(events, [
                .type(.taskCreated) { $0.commandID == addKey },
                .type(.taskContractChanged) { $0.commandID == contractKey },
                .type(.taskReady) { $0.commandID == contractKey },
                .type(.reviewStarted) { $0.id == review.id },
            ])
            try checkApproval(events, after: review, action: action.id, world: world, builder: builder)
            let wroteOneLine = try Data(contentsOf: touchFile) == Data("1\n".utf8)
            #expect(wroteOneLine, "the stand-in performed the action once")

            let decisions = try await world.owner.listDecisions().decisions
            let approval = try #require(decisions.first { $0.kind == .approval && $0.actionID == action.id })
            #expect(approval.taskID == task && approval.seatID == world.orchestrator)
            #expect(!approval.undoable)
            let beforeOverturn = try await world.owner.task(id: task)
            let overturnKey = IdempotencyKey()
            let overturn = try await world.owner.overturnApproval(actionID: action.id, key: overturnKey)
            try #require(overturn.outcome == .completed)
            let recorded = try await world.waitFor("action.overturn_recorded", task: task) {
                $0.taskID == task && $0.type == .actionOverturnRecorded && $0.commandID == overturnKey.value
            }
            #expect(recorded.seq > done.seq && recorded.actorKind == .owner && recorded.subjectID == action.id)
            let afterOverturn = try await world.owner.task(id: task)
            #expect(afterOverturn.task.state == .done)
            #expect(try publishAction(afterOverturn).state == .done)
            let sameTask = afterOverturn.task == beforeOverturn.task
            let sameAction = afterOverturn.actions == beforeOverturn.actions
            #expect(sameTask && sameAction, "overturn only records the owner's decision")
            let overturned = try await world.owner.listDecisions().decisions.first { $0.actionID == action.id }
            #expect(overturned?.overturnEffect == .recordedOnly)
        }
    }

    @Test
    func testStoppedThenSentBack() async throws {
        try await withQuestionsApprovalsWorld("stopped-action", configure: { world in
            var scenario = QuestionsApprovalsScenario()
            scenario.approvalDecisions = ["STOP", "APPROVE"]
            scenario.actionTouchFile = world.folder.url.appendingPathComponent("published.txt").path
            return scenario
        }) { world in
            let builder = try await world.managedBuilder()
            let added = try await addPublishTask(world)
            let task = added.task
            let opened = try await inboxOpened(.stoppedAction, task: task, world: world)
            let beforeRework = try await world.owner.task(id: task)
            let action = try publishAction(beforeRework)
            let item = try await openInboxItem(opened, kind: .stoppedAction, task: task, world: world)
            #expect(action.state == .stopped)
            #expect(item.actionID == action.id && item.anyActionStarted == false)
            #expect(Set(item.choices) == [.waive, .returnForRework, .cancel])
            let showedStopReason = item.detail == "The stand-in stopped it."
            #expect(showedStopReason, "Needs you shows the orchestrator's reason for stopping the action")
            let touchFile = world.folder.url.appendingPathComponent("published.txt")
            #expect(!FileManager.default.fileExists(atPath: touchFile.path))
            let events = await world.follower.events(of: task)
            let orchestrator = world.orchestrator
            try questionsApprovalsOrder(events, [
                .type(.actionStopped) {
                    $0.actorKind == .seat && $0.actorID == orchestrator && $0.subjectID == action.id
                },
                .type(.holdOpened) { $0.string("reason") == "action_stopped" && $0.subjectID == item.holdID },
                .type(.inboxOpened) { $0.id == opened.id },
            ])

            let criterion = try #require(beforeRework.criteria.first { $0.kind == .build }?.id)
            let reviewCriterion = try #require(beforeRework.criteria.first { $0.kind == .review }?.id)
            let reworkKey = IdempotencyKey()
            let rework = try await world.owner.returnForRework(
                taskID: task, ReturnForReworkRequest(criterionIDs: [criterion]), key: reworkKey)
            try #require(rework.outcome == .completed)
            _ = try await world.waitForDone(task)
            let done = try await world.owner.task(id: task)
            let reworkEvents = done.events.filter { $0.commandID == reworkKey.value }
            #expect(reworkEvents.map(\.type) == [
                .taskReturnedForRework, .criterionReopened, .criterionReopened, .actionWithdrawn, .holdClosed, .inboxResolved,
            ])
            try questionsApprovalsOrder(reworkEvents, after: opened.seq, [
                .type(.taskReturnedForRework) { $0.actorKind == .owner && $0.id("lease_seat_id") == builder },
                .type(.criterionReopened) { $0.subjectID == criterion },
                .type(.criterionReopened) { $0.subjectID == reviewCriterion },
                .type(.actionWithdrawn) { $0.subjectID == action.id },
                .type(.holdClosed) { $0.subjectID == item.holdID && $0.string("reason") == "action_stopped" },
                .type(.inboxResolved) { $0.subjectID == item.id && $0.string("choice") == "return_for_rework" },
            ])
            let resolved = try #require(reworkEvents.last?.seq)
            let reviewer = world.reviewer
            // The helper owns the run's token. Following its fresh lease through
            // acknowledgement and submit shows that its get_next delivered rework.
            try questionsApprovalsOrder(done.events, after: resolved, [
                .type(.taskBriefingAcknowledged) { $0.actorID == builder },
                .type(.criterionPassed) { $0.actorID == builder && $0.subjectID == criterion },
                .type(.taskSubmitted) { $0.actorID == builder },
                .type(.reviewPassed) { $0.actorID == reviewer },
                .type(.actionRequested) { $0.subjectID == action.id },
                .type(.actionApproved) { $0.actorID == orchestrator && $0.subjectID == action.id },
                .type(.actionStarted) { $0.actorID == builder && $0.subjectID == action.id },
                .type(.actionReportedDone) { $0.actorID == builder && $0.subjectID == action.id },
                .type(.taskDone),
            ])
            let claims = done.events.filter { $0.type == .taskClaimed }.map(\.actorID)
            #expect(claims == [builder])
            let openedRoundLimit = done.events.contains { $0.type == .holdOpened && $0.string("reason") == "rounds_exceeded" }
            #expect(!openedRoundLimit)
            // The contract counts review rounds from zero (PRD L239, trace 03).
            #expect(done.reviews.map(\.round).sorted() == [0, 1])
            #expect(done.task.round == 1)
            let wroteOneLine = try Data(contentsOf: touchFile) == Data("1\n".utf8)
            #expect(wroteOneLine, "the stand-in performed the action once after rework")
        }
    }

    @Test
    func testBuilderLostAfterApproval() async throws {
        try await withQuestionsApprovalsWorld("builder-lost-after-approval", configure: { world in
            var scenario = QuestionsApprovalsScenario()
            scenario.actionResults = ["CANNOT"]
            scenario.actionGateFile = world.folder.url.appendingPathComponent("action.go").path
            return scenario
        }) { world in
            let builder = try await world.managedBuilder()
            let added = try await addPublishTask(world)
            let task = added.task
            let orchestrator = world.orchestrator
            let approved = try await world.waitFor("action.approved", task: task) {
                $0.taskID == task && $0.type == .actionApproved && $0.actorID == orchestrator
            }
            let action = try #require(approved.subjectID)
            #expect(approved.id("lease_seat_id") == builder)
            let other = try await world.managedBuilder(name: "Two")
            try Data().write(to: world.folder.url.appendingPathComponent("action.go"))

            let opened = try await inboxOpened(.unconfirmedAction, task: task, world: world)
            let item = try await openInboxItem(opened, kind: .unconfirmedAction, task: task, world: world)
            #expect(item.actionIDs == [action])
            #expect(item.approvedByKind == .seat && item.approvedByID == orchestrator)
            #expect(item.builderAnnouncedStart == true)
            #expect(item.choices.contains(.markDone))
            try questionsApprovalsOrder(await world.follower.events(of: task), after: approved.seq, [
                .type(.actionStarted) { $0.actorID == builder && $0.subjectID == action },
                .type(.taskReleased) { $0.actorID == builder && $0.string("reason") == "unable_to_continue" },
                .type(.holdOpened) { $0.string("reason") == "action_unconfirmed" && $0.subjectID == item.holdID },
                .type(.inboxOpened) { $0.id == opened.id },
            ])

            try await waitForTwoPolls(of: other, world: world, after: opened.seq)
            let unconfirmed = try await world.owner.task(id: task)
            #expect(unconfirmed.task.state == .finishing && unconfirmed.task.holderSeatID == nil)
            #expect(try publishAction(unconfirmed).state == .started)
            let otherClaimed = unconfirmed.events.contains { $0.type == .taskClaimed && $0.actorID == other }
            #expect(!otherClaimed)

            let markKey = IdempotencyKey()
            let marked = try await world.owner.markActionDone(actionID: action, key: markKey)
            try #require(marked.outcome == .completed)
            _ = try await world.waitForDone(task)
            let done = try await world.owner.task(id: task)
            let ownerEvents = done.events.filter { $0.commandID == markKey.value }
            // Trace 22 settles the task when the last hold closes, before its item resolves.
            #expect(ownerEvents.map(\.type) == [.actionMarkedDone, .holdClosed, .taskDone, .inboxResolved])
            try questionsApprovalsOrder(ownerEvents, after: opened.seq, [
                .type(.actionMarkedDone) { $0.actorKind == .owner && $0.subjectID == action },
                .type(.holdClosed) { $0.subjectID == item.holdID && $0.string("reason") == "action_unconfirmed" },
                .type(.taskDone),
                .type(.inboxResolved) { $0.subjectID == item.id && $0.string("choice") == "mark_done" },
            ])
            #expect(done.task.state == .done && done.task.holderSeatID == nil)
            #expect(try publishAction(done).state == .done)
        }
    }
}

private func addPublishTask(_ world: QuestionsApprovalsWorld) async throws -> AddedTask {
    let action = ActionInput(kind: .publish, description: "Publish the sample page for \(world.marker("action")).")
    return try await world.addTask(title: "Prepare the sample page", actions: [action])
}

private func publishAction(_ page: TaskPage) throws -> Action {
    try #require(page.actions.count == 1)
    let action = try #require(page.actions.first)
    #expect(action.kind == .publish)
    return action
}

private func checkApproval(
    _ events: [EventRecord], after review: EventRecord, action: UUID, world: QuestionsApprovalsWorld, builder: UUID
) throws {
    let orchestrator = world.orchestrator
    let request = try questionsApprovalsOrder(events, after: review.seq, [
        .type(.reviewPassed) { $0.subjectID == review.subjectID },
        .type(.actionRequested) { $0.subjectID == action },
        .type(.checkQueued) { $0.id("action_id") == action && $0.string("hook") == "action.requested" },
    ])
    let check = try #require(request.last)
    let job = try #require(check.id("job_id"))
    // Approval is a check job and follows the contract's check result order.
    let settled = try questionsApprovalsOrder(events, after: check.seq, [
        .type(.jobQueued) { $0.subjectID == job && $0.string("kind") == "approval" },
        .type(.jobClaimed) { $0.subjectID == job && $0.actorKind == .seat && $0.actorID == orchestrator },
        .type(.jobFinished) { $0.subjectID == job && $0.actorID == orchestrator },
        .type(.checkFinished) {
            $0.subjectID == check.subjectID && $0.id("subject_id") == action
                && $0.string("result") == "applied" && $0.string("effect") == "approved"
        },
        .type(.costReported) { $0.subjectID == job && $0.actorID == orchestrator },
        .type(.actionApproved) {
            $0.subjectID == action && $0.actorKind == .seat && $0.actorID == orchestrator
                && $0.id("lease_seat_id") == builder
        },
    ])
    let approved = try #require(settled.last)
    let resultKey = try #require(approved.commandID)
    #expect(settled.suffix(4).map(\.commandID) == Array(repeating: resultKey, count: 4))
    try questionsApprovalsOrder(events, after: approved.seq, [
        .type(.taskBriefingAcknowledged) { $0.actorID == builder },
        .type(.actionStarted) { $0.actorID == builder && $0.subjectID == action },
        .type(.actionReportedDone) { $0.actorID == builder && $0.subjectID == action },
        .type(.taskDone),
    ])
}

private func inboxOpened(_ kind: NeedsYouItem, task: UUID, world: QuestionsApprovalsWorld) async throws -> EventRecord {
    try await world.waitFor("inbox.opened (\(kind.rawValue))", task: task) {
        $0.taskID == task && $0.type == .inboxOpened && $0.string("kind") == kind.rawValue
    }
}

private func openInboxItem(
    _ opened: EventRecord, kind: NeedsYouItem, task: UUID, world: QuestionsApprovalsWorld
) async throws -> InboxItem {
    let items = try await world.owner.listInbox(afterSeq: nil, wait: nil).items
    let item = try #require(items.first { $0.id == opened.subjectID })
    #expect(item.kind == kind && item.state == .open && item.aboutKind == .task && item.aboutID == task)
    #expect(item.openedSeq == opened.seq)
    return item
}

private func waitForTwoPolls(of seat: UUID, world: QuestionsApprovalsWorld, after seq: Int) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: Patience.scaled(.seconds(120)))
    var cursor = seq
    var observations: Set<Date> = []
    while clock.now < deadline {
        if let polled = try await world.owner.seats().seats.first(where: { $0.id == seat })?.lastPolledAt {
            observations.insert(polled)
            if observations.count == 3 { return }
        }
        // A last-polled write has no event. Long-poll briefly between reads.
        let events = try await world.owner.events(afterSeq: cursor, limit: 500, wait: 2)
        cursor = events.nextAfterSeq
    }
    throw EndToEndFailure("the second builder's last-polled time did not move twice")
}
