import Foundation
import LeverageKit
import LeverageTestSupport
import Testing

@Suite(.enabled(if: questionsApprovalsEnabled), .timeLimit(.minutes(Patience.minutes(8))))
struct QuestionEndToEndTests {
    @Test func testOrchestratorDecidesAndOwnerOverturns() async throws {
        try await withQuestionsApprovalsWorld("question-decision", configure: { world in
            .init(questionAnswers: ["DECISION:\(world.marker("answer"))"])
        }) { world in
            let (seat, builder, _) = try await world.manualBuilder()
            let task = try await world.addTask(title: "Choose a sample").task
            _ = try await claimManualTask(task, seat: seat, builder: builder, world: world)
            let (question, askKey, request) = try await askBlockingQuestion(task, builder: builder, world: world)
            _ = try await world.waitFor("the orchestrator's answer", task: task) {
                $0.type == .questionAnswered && $0.subjectID == question
            }
            let page = try await world.owner.task(id: task)
            #expect(page.holds.isEmpty)
            #expect(!page.steps.map(\.kind).contains(.waitOwner))
            let inbox = try await world.owner.listInbox(afterSeq: nil, wait: nil)
            let taskIsInInbox = inbox.items.contains { $0.aboutID == task }
            #expect(!taskIsInInbox)

            try await expectQuestionNotice(builder, question)
            let decided = try await builder.getQuestion(taskID: task, questionID: question)
            #expect(decided.id == question)
            #expect(decided.basis == .decision)
            let expectedAnswer = decided.answer == world.marker("answer")
            #expect(expectedAnswer, "get_question returned the orchestrator's answer")
            let expectedQuestion = decided.text == request.text && decided.assumption == request.assumption
            #expect(expectedQuestion, "get_question returned the question and assumption")
            #expect(try await builder.next(wait: nil).kind == .none)

            let decisions = try await world.owner.listDecisions()
            let matchingDecision = decisions.decisions.filter { $0.questionID == question }.only
            guard let decision = matchingDecision else {
                throw EndToEndFailure("Decided for you did not list the question exactly once")
            }
            #expect(decision.kind == .question)
            #expect(decision.taskID == task)
            #expect(decision.seatID == world.orchestrator)
            #expect(decision.undoable)

            let overturnKey = IdempotencyKey()
            _ = try await world.owner.overturnAnswer(questionID: question, key: overturnKey).completedResult()
            try await expectQuestionNotice(builder, question)
            let withdrawn = try await builder.getQuestion(taskID: task, questionID: question)
            #expect(withdrawn.outcome == .overturned)
            #expect(withdrawn.overturned)
            #expect(try await builder.next(wait: nil).kind == .none)

            let answerKey = IdempotencyKey()
            let ownerAnswer = "Use the first sample."
            _ = try await world.owner.answerQuestion(
                questionID: question, AnswerQuestionRequest(answer: ownerAnswer), key: answerKey).completedResult()
            try await expectQuestionNotice(builder, question)
            let replaced = try await builder.getQuestion(taskID: task, questionID: question)
            #expect(replaced.basis == .owner)
            let expectedReplacement = replaced.answer == ownerAnswer
            #expect(expectedReplacement, "get_question returned the owner's replacement")
            #expect(try await builder.next(wait: nil).kind == .none)

            try await finishManualTask(task, builder: builder, world: world)
            let events = try await world.wholeLog().filter { $0.taskID == task }
            let orchestrator: UUID = world.orchestrator
            let job = try verifyQuestionJob(events, question: question, askKey: askKey, orchestrator: orchestrator)
            let terminal = try questionsApprovalsOrder(events, after: job.seq, [
                .type(.questionAnswered) {
                    $0.subjectID == question && $0.actorID == orchestrator
                        && $0.payload["basis"]?.stringValue == "decision"
                },
                .type(.questionOverturned) { $0.subjectID == question && $0.commandID == overturnKey.value },
                .type(.questionAnswered) {
                    $0.subjectID == question && $0.commandID == answerKey.value
                        && $0.actorKind == .owner && $0.payload["basis"]?.stringValue == "owner"
                },
                .type(.taskDone)
            ])
            #expect(terminal.first?.commandID == job.commandID)
            let openedHold = events.contains { $0.type == .holdOpened }
            #expect(!openedHold)
        }
    }

    @Test func testPassedOnQuestionHoldsUntilAnswered() async throws {
        try await withQuestionsApprovalsWorld("question-pass-on", configure: { _ in
            .init(questionAnswers: ["PASS_ON"])
        }) { world in
            let (seat, builder, _) = try await world.manualBuilder()
            let task = try await world.addTask(title: "Confirm a sample with the owner").task
            _ = try await claimManualTask(task, seat: seat, builder: builder, world: world)
            let (question, askKey, request) = try await askBlockingQuestion(task, builder: builder, world: world)
            _ = try await world.waitFor("the passed-on question in Needs you", task: task) {
                $0.type == .inboxOpened && $0.taskID == task && $0.payload["kind"]?.stringValue == "question_passed_on"
            }

            let inbox = try await world.owner.listInbox(afterSeq: nil, wait: nil)
            guard let item = inbox.items.filter({ $0.aboutID == task }).only else {
                throw EndToEndFailure("Needs you did not list exactly one item for the question task")
            }
            #expect(item.kind == .questionPassedOn)
            #expect(item.aboutKind == .task)
            #expect(item.questionID == question)
            #expect(item.choices == [.answer])

            let page = try await world.owner.task(id: task)
            let hold = try #require(page.holds.only)
            #expect(hold.reason == .ownerQuestion)
            #expect(hold.closedAt == nil)
            #expect(item.holdID == hold.id)
            let criterion = try #require(page.criteria.filter { $0.kind == .build }.only?.id)
            let blockedKey = IdempotencyKey()
            let refused = try await builder.passCriterion(
                taskID: task, criterionID: criterion, evidence: manualEvidence, key: blockedKey)
            #expect(refused.outcome == .refused)
            #expect(refused.refusal?.code == .onHold)

            let answerKey = IdempotencyKey()
            _ = try await world.owner.answerQuestion(
                questionID: question, AnswerQuestionRequest(answer: request.assumption), key: answerKey).completedResult()
            try await resumeManualTask(task, builder: builder, world: world)
            try await expectQuestionNotice(builder, question)
            let answered = try await builder.getQuestion(taskID: task, questionID: question)
            #expect(answered.basis == .owner)
            let usedAssumption = answered.answer == request.assumption
            #expect(usedAssumption, "get_question returned the assumption the owner used")
            #expect(try await builder.next(wait: nil).kind == .none)
            let openInbox = try await world.owner.listInbox(afterSeq: nil, wait: nil)
            let stillOpen = openInbox.items.contains { $0.id == item.id }
            #expect(!stillOpen)

            try await finishManualTask(task, builder: builder, world: world)
            let events = try await world.wholeLog().filter { $0.taskID == task }
            let job = try verifyQuestionJob(events, question: question, askKey: askKey, orchestrator: world.orchestrator)
            try questionsApprovalsOrder(events, after: job.seq, [
                .type(.holdOpened) {
                    $0.subjectID == hold.id && $0.payload["reason"]?.stringValue == "owner_question"
                        && $0.commandID == job.commandID
                },
                .type(.inboxOpened) { $0.subjectID == item.id && $0.commandID == job.commandID },
                .type(.questionAnswered) {
                    $0.subjectID == question && $0.commandID == answerKey.value
                        && $0.actorKind == .owner && $0.payload["basis"]?.stringValue == "owner"
                },
                .type(.holdClosed) { $0.subjectID == hold.id && $0.commandID == answerKey.value },
                .type(.inboxResolved) { $0.subjectID == item.id && $0.commandID == answerKey.value },
                .type(.taskDone)
            ])
            let refusedCommandWroteEvents = events.contains { $0.commandID == blockedKey.value }
            #expect(!refusedCommandWroteEvents)
            let donePage = try await world.owner.task(id: task)
            try verifyOwnerWait(donePage, hold: hold.id)
        }
    }

    private func askBlockingQuestion(
        _ task: UUID, builder: AgentClient, world: QuestionsApprovalsWorld
    ) async throws -> (UUID, IdempotencyKey, AskQuestionRequest) {
        let request = AskQuestionRequest(
            text: "Which sample should I use for \(world.marker("question"))?",
            assumption: "Use the first sample for \(world.marker("assumption")).", blocking: true)
        let key = IdempotencyKey()
        let outcome = try await builder.askQuestion(taskID: task, request, key: key)
        let question = try #require(try outcome.completedResult()?.questionID, "ask_question returned a question")
        return (question, key, request)
    }

    private func expectQuestionNotice(_ builder: AgentClient, _ question: UUID) async throws {
        #expect(try await builder.next(wait: nil) == NextItem(kind: .answer, id: question.contractString))
    }

    private func verifyQuestionJob(
        _ events: [EventRecord], question: UUID, askKey: IdempotencyKey, orchestrator: UUID
    ) throws -> EventRecord {
        let routed = try questionsApprovalsOrder(events, [
            .type(.questionAsked) {
                $0.subjectID == question && $0.commandID == askKey.value && $0.payload["blocking"]?.boolValue == true
            },
            .type(.checkFinished) {
                $0.commandID == askKey.value && $0.payload["result"]?.stringValue == "applied"
                    && $0.payload["effect"]?.stringValue == "to_orchestrator"
            },
            .type(.jobQueued) { $0.commandID == askKey.value && $0.payload["kind"]?.stringValue == "question" }
        ])
        let jobID = try #require(routed.last?.subjectID)
        let queued = try #require(routed.last?.seq)
        let ran = try questionsApprovalsOrder(events, after: queued, [
            .type(.jobClaimed) { $0.subjectID == jobID && $0.actorKind == .seat && $0.actorID == orchestrator },
            .type(.jobFinished) { $0.subjectID == jobID && $0.actorID == orchestrator },
            .type(.costReported) { $0.subjectID == jobID && $0.actorID == orchestrator }
        ])
        guard let finished = ran.first(where: { $0.type == .jobFinished }), let cost = ran.last else {
            throw EndToEndFailure("Question job is missing its finish or cost event")
        }
        #expect(finished.commandID != nil)
        #expect(finished.commandID == cost.commandID)
        #expect(ran.first?.commandID != nil)
        #expect(ran.first?.commandID != finished.commandID)
        return cost
    }

    private func verifyOwnerWait(_ page: TaskPage, hold: UUID) throws {
        let wait = try #require(page.steps.indices.filter { page.steps[$0].kind == .waitOwner }.only)
        try #require(wait > 0 && wait + 1 < page.steps.count)
        #expect(page.steps[wait].subjectKind == .hold)
        #expect(page.steps[wait].subjectID == hold)
        #expect(page.steps[(wait - 1)...(wait + 1)].map(\.kind) == [.build, .waitOwner, .build])
        for (previous, next) in zip(page.steps, page.steps.dropFirst()) {
            #expect(previous.closedAt == next.openedAt)
        }
        #expect(abs(page.steps.reduce(0) { $0 + $1.seconds } - page.lifetimeSeconds) <= 0.000_001)
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}

private let manualEvidence = EvidenceInput(kind: .note, value: "criterion-1.txt records the sample.")

func claimManualTask(
    _ task: UUID, seat: UUID, builder: AgentClient, world: QuestionsApprovalsWorld
) async throws -> TaskClaim {
    _ = try await world.waitFor("the task is ready", task: task) { $0.type == .taskReady && $0.taskID == task }
    #expect(try await builder.next(wait: nil).kind == .task)
    let claimKey = IdempotencyKey()
    let outcome = try await builder.claimNextTask(key: claimKey)
    guard let claim = try outcome.completedResult() else {
        throw EndToEndFailure("claim_next_task did not return a lease")
    }
    #expect(claim.task.id == task)
    #expect(claim.lease.seatID == seat)
    #expect(claim.credentialID == nil)
    let acknowledged = try await acknowledgeManualTask(task, builder: builder)
    let events = try await world.owner.task(id: task).events
    try questionsApprovalsOrder(events, [
        .type(.taskClaimed) { $0.actorID == seat && $0.commandID == claimKey.value },
        .type(.taskBriefingAcknowledged) { $0.actorID == seat && $0.commandID == acknowledged.value }
    ])
    return claim
}

func resumeManualTask(_ task: UUID, builder: AgentClient, world: QuestionsApprovalsWorld) async throws {
    #expect(try await builder.next(wait: nil) == NextItem(kind: .resume, id: task.contractString))
    let key = try await acknowledgeManualTask(task, builder: builder)
    let events = try await world.owner.task(id: task).events
    try questionsApprovalsOrder(events, [.type(.taskBriefingAcknowledged) { $0.commandID == key.value }])
}

private func acknowledgeManualTask(_ task: UUID, builder: AgentClient) async throws -> IdempotencyKey {
    let key = IdempotencyKey()
    let briefing = try await builder.taskBriefing(taskID: task).briefing
    _ = try await builder.acknowledgeTaskBriefing(taskID: task, briefingHash: briefing.hash, key: key).completedResult()
    return key
}

func finishManualTask(_ task: UUID, builder: AgentClient, world: QuestionsApprovalsWorld) async throws {
    try Data("Prepared the sample.\n".utf8).write(to: world.work.appendingPathComponent("criterion-1.txt"))
    let page = try await world.owner.task(id: task)
    let criterion = try #require(page.criteria.filter { $0.kind == .build }.only?.id)
    let passKey = IdempotencyKey()
    _ = try await builder.passCriterion(
        taskID: task, criterionID: criterion, evidence: manualEvidence, key: passKey).completedResult()
    let submitKey = IdempotencyKey()
    _ = try await builder.submitTask(
        taskID: task, SubmitTaskRequest(handoffNote: "The sample is ready for review.", workReference: world.work.path),
        key: submitKey).completedResult()
    _ = try await world.waitForDone(task)
    let events = try await world.owner.task(id: task).events
    let reviewer = world.reviewer
    try questionsApprovalsOrder(events, [
        .type(.criterionPassed) { $0.subjectID == criterion && $0.commandID == passKey.value },
        .type(.evidenceAttached) {
            $0.commandID == passKey.value && $0.payload["criterion_id"]?.stringValue == criterion.contractString
        },
        .type(.taskSubmitted) { $0.commandID == submitKey.value },
        .type(.reviewStarted) { $0.actorID == reviewer },
        .type(.reviewPassed) { $0.actorID == reviewer },
        .type(.taskDone)
    ])
}
