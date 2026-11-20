import Foundation
import LeverageKit
import LeverageTestSupport
import SwiftUI
import Testing

@testable import LeverageApp

private typealias Fixtures = TaskScreenFixtures

@MainActor
@Suite("TaskPageModel")
struct TaskPageModelTests {
    private let taskID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!

    private let names = [
        LogName(kind: .seat, id: Fixtures.builderID, name: "Builder One"),
        LogName(kind: .seat, id: Fixtures.reviewerID, name: "Reviewer One"),
    ]

    private func ownerShowing(_ page: Locked<TaskPage>) -> FakeOwnerAPI {
        let owner = FakeOwnerAPI()
        owner.script {
            $0.task = { _ in page.value }
            $0.cancelTask = { _, key in Fixtures.plain(.cancel, key: key) }
            $0.allowAnotherRound = { _, key in Fixtures.plain(.allowAnotherRound, key: key) }
            $0.completeContract = { _, _, key in Fixtures.plain(.completeContract, key: key) }
            $0.promoteTask = { _, key in Fixtures.plain(.promote, key: key) }
            $0.holdTask = { _, key in Fixtures.plain(.hold, key: key) }
            $0.resumeTask = { _, key in Fixtures.plain(.resume, key: key) }
            $0.editContract = { _, _, key in Fixtures.plain(.editContract, key: key) }
            $0.overrideCheck = { _, _, key in Fixtures.plain(.overrideCheck, key: key) }
            $0.rerunCheck = { _, key in Fixtures.plain(.rerunCheck, key: key) }
            $0.draftContract = { _, key in
                .completed(DraftContractResult(jobID: UUID()), key: key.value, command: .draftContract)
            }
        }
        return owner
    }

    private func makeModel(
        _ owner: FakeOwnerAPI, reads: Locked<[Int]> = Locked([])
    ) -> TaskPageModel {
        TaskPageModel(taskID: taskID, api: owner, noteRead: { seq in reads.update { $0.append(seq) } })
    }

    private func loaded(
        _ page: TaskPage
    ) async -> (TaskPageModel, FakeOwnerAPI, Locked<TaskPage>) {
        let shared = Locked(page)
        let owner = ownerShowing(shared)
        let model = makeModel(owner)
        await model.load()
        return (model, owner, shared)
    }

    private func readyPage(_ state: TaskState = .working, holds: [Hold] = [], reviewer: Bool = true) -> TaskPage {
        Fixtures.page(
            Fixtures.summary(state, id: taskID, title: "Fix the totals", holder: Fixtures.builderID, builder: Fixtures.builderID),
            criteria: [
                Fixtures.criterion("Totals match the lines", taskID: taskID, state: .passed, evidence: [
                    CriterionEvidence(id: UUID(), criterionID: UUID(), kind: .link, value: "https://example.invalid/pr/1"),
                    CriterionEvidence(id: UUID(), criterionID: UUID(), kind: .note, value: "Checked by hand"),
                ]),
                Fixtures.criterion("The page still loads", taskID: taskID, position: 2, state: .started),
                Fixtures.criterion("An independent reviewer agrees.", taskID: taskID, position: 3, kind: .review),
            ],
            holds: holds, names: names, reviewer: reviewer)
    }

    // MARK: loading

    @Test("it starts loading, reads the task, and tells the feed where the read stood")
    func loading() async {
        let page = Locked(readyPage())
        let owner = ownerShowing(page)
        let reads = Locked<[Int]>([])
        let model = makeModel(owner, reads: reads)
        #expect(model.state == .loading)
        await model.load()
        #expect(model.state == .loaded)
        #expect(owner.calls.map(\.operation) == [.getTask])
        #expect(owner.calls.first?.path == ["id": taskID.contractString])
        #expect(reads.value == [20])
        #expect(model.title == "Fix the totals")
    }

    @Test("a task that is not there is its own state")
    func notFound() async {
        let owner = FakeOwnerAPI()
        owner.script { $0.task = { _ in throw TransportError(code: .notFound, message: "no") } }
        let model = makeModel(owner)
        await model.load()
        #expect(model.state == .notFound)
    }

    @Test("a sign-in that ended, a server that cannot be reached and any other failure are plain states")
    func failures() async {
        let owner = FakeOwnerAPI()
        let model = makeModel(owner)
        owner.script { $0.task = { _ in throw TransportError(code: .unauthenticated, message: "no") } }
        await model.load()
        #expect(model.state == .signedOut)
        owner.script { $0.task = { _ in throw URLError(.cannotConnectToHost) } }
        await model.load()
        #expect(model.state == .failed(.cannotReach))
        owner.script { $0.task = { _ in throw LeverageClientError.invalidBody } }
        await model.load()
        #expect(model.state == .failed(.somethingWentWrong))
    }

    @Test("a failed read after a good one keeps what was shown")
    func keepsWhatWasShown() async {
        let (model, owner, _) = await loaded(readyPage())
        owner.script { $0.task = { _ in throw URLError(.timedOut) } }
        await model.load()
        #expect(model.state == .failed(.cannotReach))
        #expect(model.title == "Fix the totals")
        #expect(!model.criteria.isEmpty)
    }

    // MARK: what the page shows

    @Test("the status line is the card's, with the agent named from the names of the read")
    func status() async {
        let (model, _, _) = await loaded(readyPage(.working))
        #expect(model.status?.statusLine == "Builder One is building")
        let (review, _, _) = await loaded(readyPage(.inReview, reviewer: false))
        #expect(review.status?.statusLine == "Builder One's work is being reviewed")
        #expect(review.status?.note == "No reviewer agent is connected. Connect one in Agents.")
        let (paused, _, _) = await loaded(readyPage(.working, holds: [Fixtures.hold(.roundsExceeded, taskID: taskID)]))
        #expect(paused.status?.statusLine == "Paused, was In progress")
        let (closed, _, _) = await loaded(readyPage(.working, holds: [Fixtures.hold(.roundsExceeded, taskID: taskID, open: false)]))
        #expect(closed.status?.statusLine == "Builder One is building")
    }

    @Test("the criteria come in order with their state in words and their evidence as plain text")
    func criteria() async {
        let (model, _, _) = await loaded(readyPage())
        #expect(model.criteria.map(\.text) == ["Totals match the lines", "The page still loads", "An independent reviewer agrees."])
        #expect(model.criteria.map(\.stateText) == ["Done", "In progress", "Not started"])
        #expect(model.criteria[0].evidence.map(\.value) == ["https://example.invalid/pr/1", "Checked by hand"])
        #expect(model.criteria[0].evidence.map(\.kindText) == ["Link", "Note"])
        #expect(model.criteria[1].evidence.isEmpty)
    }

    @Test("the goal, details, priority and where the work is come from the task")
    func contract() async {
        let task = Fixtures.summary(
            .working, id: taskID, goal: "The totals are right.", details: "For finance.",
            workReference: "~/work/invoices", priority: .high)
        let (model, _, _) = await loaded(Fixtures.page(task))
        #expect(model.goal == "The totals are right.")
        #expect(model.details == "For finance.")
        #expect(model.workReference == "~/work/invoices")
        #expect(model.priorityText == "High")
        let (bare, _, _) = await loaded(Fixtures.page(Fixtures.summary(.working, id: taskID)))
        #expect(bare.details == nil)
        #expect(bare.workReference == nil)
    }

    @Test("the log is the task's events as sentences, newest last")
    func log() async {
        let events = [
            Fixtures.event(.taskCreated, seq: 1, taskID: taskID, actorKind: .owner),
            Fixtures.event(.taskClaimed, seq: 2, taskID: taskID, actor: Fixtures.builderID),
        ]
        let page = Fixtures.page(Fixtures.summary(.working, id: taskID), events: events, names: names)
        let (model, _, _) = await loaded(page)
        #expect(model.log.map(\.text) == ["You added the task.", "Builder One took the task."])
    }

    // MARK: Backlog: the form, and Send to agents (MA-16)

    private func backlogPage(title: String = "Fix the totals") -> TaskPage {
        Fixtures.page(
            Fixtures.summary(.backlog, id: taskID, title: title, goal: "The totals are right.", details: "For finance.", workReference: "~/work/invoices"),
            criteria: [Fixtures.criterion("Totals match the lines", taskID: taskID)], names: names)
    }

    @Test("a task in Backlog shows the form filled in, and other tasks do not")
    func backlogForm() async {
        let (model, _, _) = await loaded(backlogPage())
        #expect(model.showsContractForm)
        #expect(model.draft.title == "Fix the totals")
        #expect(model.draft.goal == "The totals are right.")
        #expect(model.draft.details == "For finance.")
        #expect(model.draft.workReference == "~/work/invoices")
        #expect(model.draft.criteriaText == "Totals match the lines")
        #expect(model.canSend)
        let (working, _, _) = await loaded(readyPage())
        #expect(!working.showsContractForm)
    }

    @Test("Send to agents sends Complete contract for this task with the form's values")
    func sendToAgents() async {
        let (model, owner, page) = await loaded(backlogPage())
        model.draft.title = "Fix the totals, all of them"
        model.draft.criteriaText = "One\nTwo"
        page.value = Fixtures.page(Fixtures.summary(.ready, id: taskID), names: names)

        await model.sendToAgents()

        #expect(owner.calls.map(\.operation) == [.getTask, .completeContract, .getTask])
        let call = owner.calls[1]
        #expect(call.path == ["id": taskID.contractString])
        #expect(call.body?["title"] == .string("Fix the totals, all of them"))
        #expect(call.body?["goal"] == .string("The totals are right."))
        #expect(call.body?["details"] == .string("For finance."))
        #expect(call.body?["work_reference"] == .string("~/work/invoices"))
        #expect(call.body?["actions"] == .array([]))
        #expect(call.body?["criteria"]?.arrayValue?.compactMap { $0["text"]?.stringValue } == [
            "One", "Two", AddTaskCopy.reviewCriterion.text,
        ])
        #expect(!model.showsContractForm)
        #expect(model.actionFailure == nil)
    }

    @Test("retrying Send to agents reuses the key, and an edited form gets a new one")
    func sendRetryKey() async {
        let (model, owner, _) = await loaded(backlogPage())
        owner.script { $0.completeContract = { _, _, _ in throw URLError(.networkConnectionLost) } }
        await model.sendToAgents()
        #expect(model.actionFailure == .cannotReach)
        await model.sendToAgents()
        model.draft.title = "Changed"
        await model.sendToAgents()
        let keys = owner.calls.filter { $0.operation == .completeContract }.map(\.key)
        #expect(keys.count == 3)
        #expect(keys[0] == keys[1])
        #expect(keys[1] != keys[2])
    }

    @Test("a read again does not overwrite what the owner is typing into the form")
    func draftSurvivesReload() async {
        let (model, _, _) = await loaded(backlogPage())
        model.draft.title = "Typed by the owner"
        await model.load()
        #expect(model.draft.title == "Typed by the owner")
    }

    @Test("a form with no title cannot be sent")
    func sendNeedsTitle() async {
        let (model, owner, _) = await loaded(backlogPage())
        model.draft.title = "  "
        #expect(!model.canSend)
        await model.sendToAgents()
        #expect(owner.calls.allSatisfy { $0.operation == .getTask })
    }

    // MARK: Allow one more round, and Cancel task (MA-29)

    @Test("a task paused at the round limit offers both choices, and nothing else is offered")
    func roundDecision() async {
        let (paused, _, _) = await loaded(readyPage(.working, holds: [Fixtures.hold(.roundsExceeded, taskID: taskID)]))
        #expect(paused.needsRoundDecision)
        let (other, _, _) = await loaded(readyPage(.working, holds: [Fixtures.hold(.ownerApproval, taskID: taskID)]))
        #expect(!other.needsRoundDecision)
        let (closed, _, _) = await loaded(readyPage(.working, holds: [Fixtures.hold(.roundsExceeded, taskID: taskID, open: false)]))
        #expect(!closed.needsRoundDecision)
        let (plain, _, _) = await loaded(readyPage(.working))
        #expect(!plain.needsRoundDecision)
    }

    @Test("Allow one more round sends that command for this task, reads again, and uses a new key next time")
    func allowRound() async {
        let (model, owner, page) = await loaded(readyPage(.working, holds: [Fixtures.hold(.roundsExceeded, taskID: taskID)]))
        page.value = readyPage(.working)
        await model.allowAnotherRound()
        #expect(owner.calls.map(\.operation) == [.getTask, .allowAnotherRound, .getTask])
        #expect(owner.calls[1].path == ["id": taskID.contractString])
        #expect(owner.calls[1].body == nil)
        #expect(!model.needsRoundDecision)

        page.value = readyPage(.working, holds: [Fixtures.hold(.roundsExceeded, taskID: taskID)])
        await model.load()
        await model.allowAnotherRound()
        let keys = owner.calls.filter { $0.operation == .allowAnotherRound }.map(\.key)
        #expect(keys.count == 2 && keys[0] != keys[1])
    }

    @Test("Allow one more round that failed is sent again with the same key")
    func allowRoundRetry() async {
        let (model, owner, _) = await loaded(readyPage(.working, holds: [Fixtures.hold(.roundsExceeded, taskID: taskID)]))
        owner.script { $0.allowAnotherRound = { _, _ in throw URLError(.timedOut) } }
        await model.allowAnotherRound()
        #expect(model.actionFailure == .cannotReach)
        await model.allowAnotherRound()
        let keys = owner.calls.filter { $0.operation == .allowAnotherRound }.map(\.key)
        #expect(keys.count == 2 && keys[0] == keys[1])
    }

    @Test("every task that is not Done or Cancelled can be cancelled; a finished one cannot")
    func canCancel() async {
        for state in TaskState.allCases {
            let (model, _, _) = await loaded(Fixtures.page(Fixtures.summary(state, id: taskID), names: names))
            #expect(model.canCancel == (state != .done && state != .cancelled), "\(state)")
        }
    }

    @Test("Cancel task asks first: nothing is sent until the owner confirms, and Keep does not send it")
    func cancelNeedsConfirmation() async {
        let (model, owner, _) = await loaded(readyPage())
        #expect(!model.isConfirmingCancel)
        model.askToCancel()
        #expect(model.isConfirmingCancel)
        #expect(owner.calls.map(\.operation) == [.getTask])
        model.dismissCancel()
        #expect(!model.isConfirmingCancel)
        #expect(owner.calls.map(\.operation) == [.getTask])
    }

    @Test("confirming sends Cancel task for this task once, closes the question and reads again")
    func cancelConfirmed() async {
        let (model, owner, page) = await loaded(readyPage())
        page.value = Fixtures.page(Fixtures.summary(.cancelled, id: taskID), names: names)
        model.askToCancel()
        await model.confirmCancel()
        #expect(owner.calls.map(\.operation) == [.getTask, .cancelTask, .getTask])
        #expect(owner.calls[1].path == ["id": taskID.contractString])
        #expect(!model.isConfirmingCancel)
        #expect(!model.canCancel)
        #expect(model.actionFailure == nil)
    }

    @Test("a refused cancel is a plain line, and trying again uses the same key")
    func cancelRefused() async {
        let (model, owner, _) = await loaded(readyPage())
        let refusal = Refusal(code: .invalidState, ruleID: nil, reason: nil)
        owner.script { $0.cancelTask = { _, key in .refused(refusal, key: key.value, command: .cancel) } }
        model.askToCancel()
        await model.confirmCancel()
        #expect(model.actionFailure == .refusalInvalidState)
        model.askToCancel()
        await model.confirmCancel()
        let keys = owner.calls.filter { $0.operation == .cancelTask }.map(\.key)
        #expect(keys.count == 2 && keys[0] == keys[1])
    }

    // MARK: Move to Backlog, Pause this task and Continue this task (HM-45)

    private func page(_ state: TaskState, holds: [Hold] = []) -> TaskPage {
        Fixtures.page(Fixtures.summary(state, id: taskID, title: "Try a weekly summary"), holds: holds, names: names)
    }

    @Test("only an idea offers Move to Backlog, and nothing else of the page does")
    func moveToBacklogOffered() async {
        for state in TaskState.allCases {
            let (model, _, _) = await loaded(page(state))
            #expect(model.canMoveToBacklog == (state == .imaginarium), "\(state)")
        }
    }

    @Test("Move to Backlog sends Promote for this task with no body, reads again, and an idea that moved no longer offers it")
    func moveToBacklog() async throws {
        let (model, owner, shared) = await loaded(page(.imaginarium))
        shared.value = page(.backlog)
        await model.moveToBacklog()
        #expect(owner.calls.map(\.operation) == [.getTask, .promoteTask, .getTask])
        #expect((try owner.call(at: 1)).path == ["id": taskID.contractString])
        #expect((try owner.call(at: 1)).body == nil)
        #expect(model.state == .loaded)
        #expect(!model.canMoveToBacklog)
        #expect(model.showsContractForm)
        #expect(model.actionFailure == nil)
    }

    @Test("Move to Backlog that failed is sent again with the same key, and a refusal is a plain line")
    func moveToBacklogRetry() async {
        let (model, owner, _) = await loaded(page(.imaginarium))
        owner.script { $0.promoteTask = { _, _ in throw URLError(.timedOut) } }
        await model.moveToBacklog()
        #expect(model.actionFailure == .cannotReach)
        let refusal = Refusal(code: .invalidState, ruleID: nil, reason: nil)
        owner.script { $0.promoteTask = { _, key in .refused(refusal, key: key.value, command: .promote) } }
        await model.moveToBacklog()
        #expect(model.actionFailure == .refusalInvalidState)
        let keys = owner.calls.filter { $0.operation == .promoteTask }.map(\.key)
        #expect(keys.count == 2 && keys[0] == keys[1])
    }

    @Test("Pause this task is offered in every state a task can be paused from, and not while it is already paused by the owner")
    func pauseOffered() async {
        for state in TaskState.allCases {
            let (model, _, _) = await loaded(page(state))
            let expected: Bool = [.backlog, .ready, .working, .inReview].contains(state)
            #expect(model.canPause == expected, "\(state)")
        }
        let (paused, _, _) = await loaded(page(.working, holds: [Fixtures.hold(.ownerHold, taskID: taskID)]))
        #expect(!paused.canPause)
        let (released, _, _) = await loaded(page(.working, holds: [Fixtures.hold(.ownerHold, taskID: taskID, open: false)]))
        #expect(released.canPause)
        let (waiting, _, _) = await loaded(page(.working, holds: [Fixtures.hold(.credentialLimit, taskID: taskID)]))
        #expect(waiting.canPause)
    }

    @Test("Pause this task sends Hold for this task, reads again, and the page then offers Continue this task instead")
    func pauseTask() async throws {
        let (model, owner, shared) = await loaded(page(.working))
        shared.value = page(.working, holds: [Fixtures.hold(.ownerHold, taskID: taskID)])
        await model.pauseTask()
        #expect(owner.calls.map(\.operation) == [.getTask, .holdTask, .getTask])
        #expect((try owner.call(at: 1)).path == ["id": taskID.contractString])
        #expect((try owner.call(at: 1)).body == nil)
        #expect(!model.canPause)
        #expect(model.canContinue)
        #expect(model.status?.chip?.text == "Paused by you")
        #expect(model.status?.statusLine == "Paused, was In progress")
    }

    @Test("Continue this task is offered only while the owner's pause is open, and sends Resume")
    func continueTask() async throws {
        for state in TaskState.allCases {
            let (model, _, _) = await loaded(page(state, holds: [Fixtures.hold(.ownerHold, taskID: taskID)]))
            #expect(model.canContinue == (state != .done && state != .cancelled), "\(state)")
        }
        let (other, _, _) = await loaded(page(.working, holds: [Fixtures.hold(.ownerApproval, taskID: taskID)]))
        #expect(!other.canContinue)

        let (model, owner, shared) = await loaded(page(.working, holds: [Fixtures.hold(.ownerHold, taskID: taskID)]))
        shared.value = page(.working)
        await model.continueTask()
        #expect(owner.calls.map(\.operation) == [.getTask, .resumeTask, .getTask])
        #expect((try owner.call(at: 1)).path == ["id": taskID.contractString])
        #expect(!model.canContinue)
        #expect(model.canPause)
    }

    @Test("a pause or a resume that failed is sent again with the same key, and a new one after it worked uses a new key")
    func pauseKeys() async throws {
        let (model, owner, shared) = await loaded(page(.working))
        owner.script { $0.holdTask = { _, _ in throw URLError(.networkConnectionLost) } }
        await model.pauseTask()
        #expect(model.actionFailure == .cannotReach)
        owner.script { $0.holdTask = { _, key in Fixtures.plain(.hold, key: key) } }
        shared.value = page(.working, holds: [Fixtures.hold(.ownerHold, taskID: taskID)])
        await model.pauseTask()
        // The pause worked; the owner continues the task by hand elsewhere, and pauses it again.
        shared.value = page(.working)
        await model.load()
        await model.pauseTask()
        let keys = owner.calls.filter { $0.operation == .holdTask }.map(\.key)
        try #require(keys.count == 3)
        #expect(keys[0] == keys[1])
        #expect(keys[1] != keys[2])
    }

    // MARK: a task waiting for an account, on its page (HM-40, HM-45)

    @Test("a task waiting on a limit says on its page which account and when it resets, with the account's own name")
    func waitingOnALimit() async {
        let until = Fixtures.date(19, 18)
        let hold = Hold(
            id: UUID(), taskID: taskID, reason: .credentialLimit, credentialID: Fixtures.personalID,
            openedAt: Fixtures.date(19, 9))
        let shared = Locked(Fixtures.page(
            Fixtures.summary(.working, id: taskID, holder: Fixtures.builderID, builder: Fixtures.builderID),
            holds: [hold], waitingFor: Fixtures.personalID, waitingUntil: until,
            names: names + [LogName(kind: .credential, id: Fixtures.personalID, name: "Personal")]))
        let owner = ownerShowing(shared)
        owner.script { $0.credentials = { Fixtures.credentials([Fixtures.credential(Fixtures.personalID, limitedUntil: until)]) } }
        let model = TaskPageModel(taskID: taskID, api: owner, noteRead: { _ in }, clock: Fixtures.clock())
        await model.load()
        #expect(owner.calls.map(\.operation) == [.getTask, .listCredentials])
        #expect(model.status?.chip?.text == "No login left")
        #expect(model.status?.note.map(Fixtures.flat) == "Waiting for Claude, Personal, which resets at 6:00 PM.")
        #expect(model.status?.statusLine == "Builder One is building")
    }

    @Test("when the accounts cannot be read the page still names the account from the names of the read")
    func waitingNamesFromTheRead() async {
        let hold = Hold(
            id: UUID(), taskID: taskID, reason: .credentialSignedOut, credentialID: Fixtures.personalID,
            openedAt: Fixtures.date(19, 9))
        let shared = Locked(Fixtures.page(
            Fixtures.summary(.working, id: taskID), holds: [hold], waitingFor: Fixtures.personalID,
            names: [LogName(kind: .credential, id: Fixtures.personalID, name: "Personal")]))
        let owner = ownerShowing(shared)
        owner.script { $0.credentials = { throw URLError(.timedOut) } }
        let model = TaskPageModel(taskID: taskID, api: owner, noteRead: { _ in }, clock: Fixtures.clock())
        await model.load()
        #expect(model.state == .loaded)
        #expect(model.status?.note == "Personal is signed out. Sign in again to continue.")
        #expect(model.status?.statusLine == "Paused, was In progress")
    }

    // HE-15, HE-16: the read names the account a task waits for when no
    // hold does, and the page says it in the card's own words.

    private func waitingPage(
        _ state: TaskState, waitingUntil: Date? = nil, credential: Credential
    ) async -> (TaskPageModel, FakeOwnerAPI) {
        let shared = Locked(Fixtures.page(
            Fixtures.summary(state, id: taskID, builder: Fixtures.builderID), waitingFor: Fixtures.personalID,
            waitingUntil: waitingUntil, names: names))
        let owner = ownerShowing(shared)
        owner.script { $0.credentials = { Fixtures.credentials([credential]) } }
        let model = TaskPageModel(taskID: taskID, api: owner, noteRead: { _ in }, clock: Fixtures.clock())
        await model.load()
        return (model, owner)
    }

    /// What the board card says for the same read.
    private func cardContent(_ page: TaskPage?, credential: Credential) throws -> CardContent {
        let page = try #require(page)
        let card = BoardTask(
            task: page.task, blocked: false, holdReasons: [], waitingForCredentialID: page.waitingForCredentialID,
            waitingUntil: page.waitingUntil)
        return CardWording.content(
            for: card, seatNames: [Fixtures.builderID: "Builder One", Fixtures.reviewerID: "Reviewer One"],
            reviewerSeatExists: page.reviewerSeatExists, accounts: [credential.id: CardAccount(of: credential)],
            clock: Fixtures.clock())
    }

    @Test("a Ready task no agent can start because its account is signed out names the account on its page, as its card does")
    func readyWaitingOnASignedOutAccount() async throws {
        let credential = Fixtures.credential(Fixtures.personalID, state: .signedOut)
        let (model, owner) = await waitingPage(.ready, credential: credential)
        #expect(owner.calls.map(\.operation) == [.getTask, .listCredentials])
        #expect(model.status?.chip?.text == "Login signed out")
        #expect(model.status?.note == "Claude, Personal is signed out. Sign in again to continue.")
        #expect(model.status?.statusLine == "Waiting for a free agent")
        #expect(model.status == (try cardContent(model.page, credential: credential)))
    }

    @Test("a task In review no reviewer can start names the limited account and when it resets on its page, as its card does")
    func inReviewWaitingOnALimit() async throws {
        let until = Fixtures.date(19, 18)
        let credential = Fixtures.credential(Fixtures.personalID, limitedUntil: until)
        let (model, owner) = await waitingPage(.inReview, waitingUntil: until, credential: credential)
        #expect(owner.calls.map(\.operation) == [.getTask, .listCredentials])
        #expect(model.status?.chip?.text == "In review")
        #expect(model.status?.note.map(Fixtures.flat) == "Waiting for Claude, Personal, which resets at 6:00 PM.")
        #expect(model.status?.statusLine == "Builder One's work is being reviewed")
        #expect(model.status == (try cardContent(model.page, credential: credential)))
    }

    @Test("a hold's reset time comes from the read, so the page says it even when the accounts cannot be read")
    func holdResetFromTheRead() async {
        let hold = Hold(
            id: UUID(), taskID: taskID, reason: .credentialLimit, credentialID: Fixtures.personalID,
            openedAt: Fixtures.date(19, 9))
        let shared = Locked(Fixtures.page(
            Fixtures.summary(.working, id: taskID, holder: Fixtures.builderID, builder: Fixtures.builderID),
            holds: [hold], waitingFor: Fixtures.personalID, waitingUntil: Fixtures.date(19, 18),
            names: names + [LogName(kind: .credential, id: Fixtures.personalID, name: "Personal")]))
        let owner = ownerShowing(shared)
        owner.script { $0.credentials = { throw URLError(.timedOut) } }
        let model = TaskPageModel(taskID: taskID, api: owner, noteRead: { _ in }, clock: Fixtures.clock())
        await model.load()
        #expect(model.status?.chip?.text == "No login left")
        #expect(model.status?.note.map(Fixtures.flat) == "Waiting for Personal, which resets at 6:00 PM.")
    }

    @Test("a page with no account in it reads no accounts")
    func noAccountsRead() async {
        let (_, owner, _) = await loaded(readyPage())
        #expect(owner.calls.map(\.operation) == [.getTask])
    }

    // MARK: Change the task (HM-49)

    @Test("Change the task is offered for a task that is ready, working or in review, and not for the rest")
    func changeOffered() async {
        for state in TaskState.allCases {
            let (model, _, _) = await loaded(page(state))
            #expect(model.canChangeTask == [.ready, .working, .inReview].contains(state), "\(state)")
        }
    }

    @Test("a task sent back too many times offers Change the task beside the two choices it already had")
    func changeFromTheRoundDecision() async {
        let (model, _, _) = await loaded(readyPage(.working, holds: [Fixtures.hold(.roundsExceeded, taskID: taskID)]))
        #expect(model.needsRoundDecision)
        #expect(model.canChangeTask)
    }

    @Test("Change the task opens the editor filled in with the task's contract, and closing it leaves the page as it was")
    func editorOpens() async {
        let (model, owner, _) = await loaded(readyPage(.working))
        #expect(model.editor == nil)
        model.beginEditing()
        let editor = model.editor
        #expect(editor?.draft.title == "Fix the totals")
        #expect(editor?.draft.criteriaText == "Totals match the lines\nThe page still loads")
        #expect(editor?.warning == .editWarning)
        model.endEditing()
        #expect(model.editor == nil)
        #expect(owner.calls.map(\.operation) == [.getTask])
        model.beginEditing()
        model.endEditing()
        let (idle, _, _) = await loaded(page(.imaginarium))
        idle.beginEditing()
        #expect(idle.editor == nil)
    }

    @Test("opened from Needs you's Change the task, the page opens the editor once it has read the task (HM-24, HM-49)")
    func editorOpensFromNeedsYou() async {
        let shared = Locked(readyPage(.inReview, holds: [Fixtures.hold(.roundsExceeded, taskID: taskID)]))
        let owner = ownerShowing(shared)
        let model = TaskPageModel(taskID: taskID, api: owner, noteRead: { _ in }, editOnOpen: true)
        #expect(model.editor == nil)
        await model.load()
        #expect(model.editor?.draft.title == "Fix the totals")
        model.endEditing()
        await model.load()
        #expect(model.editor == nil, "only the first read opens it")

        let idea = Locked(page(.imaginarium))
        let ideaModel = TaskPageModel(taskID: taskID, api: ownerShowing(idea), noteRead: { _ in }, editOnOpen: true)
        await ideaModel.load()
        #expect(ideaModel.editor == nil, "a task the editor is not for shows its page")

        let plain = TaskPageModel(taskID: taskID, api: ownerShowing(Locked(readyPage(.working))), noteRead: { _ in })
        await plain.load()
        #expect(plain.editor == nil)
    }

    @Test("when the editor saves, the page reads again and closes it")
    func editorSaved() async {
        let (model, owner, shared) = await loaded(readyPage(.working))
        model.beginEditing()
        model.editor?.draft.title = "Fix the totals, all of them"
        shared.value = page(.backlog)
        await model.editor?.save()
        #expect(await ShellFixtures.eventually { model.editor == nil })
        #expect(await ShellFixtures.eventually { owner.calls.filter { $0.operation == .getTask }.count == 2 })
        #expect(owner.calls.map(\.operation).prefix(2) == [.getTask, .editContract])
    }

    @Test("the lines of the page are in plain words")
    func plainWords() async {
        let page = readyPage(.working, holds: [Fixtures.hold(.roundsExceeded, taskID: taskID)])
        let (model, _, _) = await loaded(page)
        for text in [model.status?.statusLine, model.status?.chip?.text, model.status?.note, model.priorityText]
            .compactMap({ $0 }) + model.criteria.map(\.stateText) + model.log.map(\.text)
        {
            #expect(BannedTerms.found(in: text).isEmpty, "\(text)")
        }
    }

    /// The items when there are exactly `count` of them: a wrong count fails the test and stops it, never the run.
    private func exactly<T>(_ items: [T], _ count: Int) throws -> [T] {
        try #require(items.count == count ? items : nil, "expected \(count) items, found \(items.count)")
    }

    // MARK: the Timing section (RD-28)

    @Test("the Timing section lists every step in order with its plain name, the open one counted to now, and a total that is the lifetime")
    func timingRows() async throws {
        let steps = [
            Fixtures.step(.idea, seconds: 600),
            Fixtures.step(.draft, .working, seconds: 90),
            Fixtures.step(.check, .ruleCheck, seconds: 45),
            Fixtures.step(.waitReady, .waiting, seconds: 3700),
            Fixtures.step(.build, seconds: 120, open: true),
        ]
        let (model, _, _) = await loaded(Fixtures.checkedPage(Fixtures.summary(.working, id: taskID), steps: steps))
        let timing = try #require(model.timing)
        #expect(timing.rows.map(\.name) == ["Writing the details", "Being checked", "Waiting for an agent", "Building"])
        #expect(timing.rows.map(\.durationText) == ["1 minute", "45 seconds", "1 hour 1 minute", "2 minutes"])
        #expect(timing.rows.map(\.isOpen) == [false, false, false, true])
        #expect(timing.beforeIdeas?.seconds == 600)
        #expect(timing.beforeIdeas?.durationText == "10 minutes")
        #expect(timing.totalSeconds == 4555)
        #expect(timing.totalText == "1 hour 15 minutes")
        let listed = timing.rows.reduce(0) { $0 + $1.seconds } + (timing.beforeIdeas?.seconds ?? 0)
        #expect(abs(listed - timing.totalSeconds) < 1, "the rows add up to the total")
    }

    @Test("every kind of step has the plain name of the table, and none uses a banned word")
    func stepNames() async throws {
        let expected: [StepKind: String] = [
            .idea: "Idea", .draft: "Writing the details", .waitContract: "Waiting for details",
            .check: "Being checked", .waitReady: "Waiting for an agent", .briefing: "Reading the task",
            .build: "Building", .finish: "Wrapping up", .waitReview: "Waiting for a reviewer", .review: "Reviewing",
            .waitBuilder: "Waiting for its agent", .rework: "Fixing after review", .waitOwner: "Waiting for you",
            .waitSeat: "Agent paused", .waitLimit: "Waiting for an account",
        ]
        #expect(Set(expected.keys) == Set(StepKind.allCases))
        for kind in StepKind.allCases {
            let page = Fixtures.checkedPage(
                Fixtures.summary(.working, id: taskID), steps: [Fixtures.step(kind, seconds: 5, open: true)])
            let (model, _, _) = await loaded(page)
            let timing = try #require(model.timing)
            let name = try #require(kind == .idea ? timing.beforeIdeas?.name : timing.rows.first?.name)
            #expect(name == expected[kind], "\(kind)")
            #expect(BannedTerms.found(in: name).isEmpty, "\(name)")
        }
    }

    @Test("a read with no steps has no Timing section")
    func noTiming() async {
        let (model, _, _) = await loaded(Fixtures.checkedPage(Fixtures.summary(.working, id: taskID)))
        #expect(model.timing == nil)
    }

    // MARK: the checklist (RD-28, RD-49)

    @Test("the checklist has one line for each check in order, with the rule's name, when it ran, the result in a word, the reason, the time and the date of its wording")
    func checklistRows() async throws {
        let passed = Fixtures.check(
            rule: "Every task needs specific details", result: .passed, reason: "It names the page and the user.",
            queue: 4, run: 8, saved: Fixtures.date(12, 9))
        let failed = Fixtures.check(
            rule: "Every submit names the tests that ran", hook: .taskBeforeSubmit, result: .failed,
            reason: "No test is named.", queue: 70, run: 5, canOverride: true)
        let (model, _, _) = await loaded(
            Fixtures.checkedPage(Fixtures.summary(.working, id: taskID), checks: [passed, failed]))
        let rows = try exactly(model.checks, 2)
        #expect(rows.map(\.id) == [passed.id, failed.id])
        #expect(rows.map(\.ruleName) == ["Every task needs specific details", "Every submit names the tests that ran"])
        #expect(rows.map(\.momentText) == ["when a task is ready to start", "before work is submitted"])
        #expect(rows.map(\.resultText) == ["Passed", "Did not pass"])
        #expect(rows.map(\.reason) == ["It names the page and the user.", "No test is named."])
        #expect(rows.map(\.timeText) == ["12 seconds", "1 minute"])
        #expect(rows[0].wordingText == "wording of Nov 12, 2026")
        #expect(rows[0].checkerText == "An agent checks this")
        #expect(rows[0].onFailText == "Stop the task")
    }

    @Test("a result is a word: passed, did not pass, did not apply, applied, could not run, not needed any more")
    func resultWords() async {
        let results: [(CheckResult, String)] = [
            (.passed, "Passed"), (.failed, "Did not pass"), (.notApplicable, "Did not apply"), (.applied, "Applied"),
            (.error, "Could not run"), (.withdrawn, "Not needed any more"),
        ]
        let checks = results.map { Fixtures.check(result: $0.0) }
        let (model, _, _) = await loaded(Fixtures.checkedPage(Fixtures.summary(.working, id: taskID), checks: checks))
        #expect(model.checks.map(\.resultText) == results.map(\.1))
    }

    @Test("a check that has no result yet is being checked, and the one held at the re-run limit says it was checked too many times")
    func unfinishedRows() async {
        let running = Fixtures.check(result: nil)
        let held = Fixtures.check(rule: "Every submit names the tests that ran", result: nil, canOverride: true)
        let (model, _, _) = await loaded(
            Fixtures.checkedPage(Fixtures.summary(.working, id: taskID), checks: [running, held]))
        #expect(model.checks.map(\.resultText) == ["Being checked", "Checked too many times"])
        #expect(model.checks.map(\.canLetThrough) == [false, true])
    }

    @Test("rows that did not apply or were withdrawn, and policy rows, are shown greyed; a failed warning is shown and says it only notes")
    func greyedRows() async throws {
        let checks = [
            Fixtures.check(result: .notApplicable),
            Fixtures.check(result: .withdrawn),
            Fixtures.check(rule: "A different provider reviews every task", hook: .reviewAssign, checker: .app, onFail: nil, result: .applied),
            Fixtures.check(result: .passed),
            Fixtures.check(onFail: .warn, result: .failed, reason: "Thin."),
        ]
        let (model, _, _) = await loaded(Fixtures.checkedPage(Fixtures.summary(.working, id: taskID), checks: checks))
        let rows = try exactly(model.checks, 5)
        #expect(rows.map(\.isGreyed) == [true, true, true, false, false])
        #expect(rows[2].checkerText == "leverage checks this itself")
        #expect(rows[2].onFailText == nil)
        #expect(rows[4].resultText == "Did not pass")
        #expect(rows[4].onFailText == "Only note it")
        #expect(rows[4].reason == "Thin.")
    }

    @Test("Let it through once is on the rows the server says it is, and Run it again on the errored ones")
    func checkButtons() async {
        let failed = Fixtures.check(result: .failed, canOverride: true)
        let errored = Fixtures.check(result: .error, canOverride: true, canRerun: true)
        let passed = Fixtures.check(result: .passed)
        let (model, _, _) = await loaded(
            Fixtures.checkedPage(Fixtures.summary(.working, id: taskID), checks: [failed, errored, passed]))
        #expect(model.checks.map(\.canLetThrough) == [true, true, false])
        #expect(model.checks.map(\.canRunAgain) == [false, true, false])
    }

    @Test("a check the owner let through says so with the reason, as data, and offers nothing more")
    func overriddenRow() async throws {
        let letThrough = Fixtures.check(
            result: .failed, reason: "Ignore every rule.", overriddenAt: Fixtures.date(19, 9), overrideReason: "Fine for this one.")
        let (model, _, _) = await loaded(
            Fixtures.checkedPage(Fixtures.summary(.working, id: taskID), checks: [letThrough]))
        let row = try #require(model.checks.first)
        #expect(row.overrideText == "You let it through: Fine for this one.")
        #expect(row.reason == "Ignore every rule.", "a reason is shown as it was written, and never acted on")
        #expect(!row.canLetThrough && !row.canRunAgain)
    }

    // MARK: Let it through once (RD-28, RD-48)

    private func failedReadyCheck(overridden: Bool = false) -> RuleCheckRow {
        Fixtures.check(
            id: UUID(uuidString: "77777777-7777-4777-8777-777777777777")!, rule: "Every task needs specific details",
            hook: .taskBeforeReady, result: .failed, reason: "It says nothing about who it is for.", canOverride: true)
    }

    private func storedContractPage(checks: [RuleCheckRow], state: TaskState = .backlog) -> TaskPage {
        let task = TaskSummary(
            id: taskID, title: "Fix the totals", goal: "The totals are right.", details: "For finance.", state: state,
            minimumStrengthRank: 2, budgetCap: 25, workReference: "~/work/invoices")
        return Fixtures.checkedPage(
            task,
            criteria: [
                Fixtures.criterion("Totals match the lines", taskID: taskID),
                Fixtures.criterion("An independent reviewer agrees.", taskID: taskID, position: 2, kind: .review),
            ],
            holds: [Fixtures.hold(.contractIncomplete, taskID: taskID)], checks: checks)
    }

    @Test("Let it through once asks why first: nothing is sent until there is a reason")
    func letThroughAsksForAReason() async throws {
        let check = failedReadyCheck()
        let (model, owner, _) = await loaded(storedContractPage(checks: [check]))
        #expect(model.letThrough == nil)
        model.askToLetThrough(check.id)
        let sheet = try #require(model.letThrough)
        #expect(sheet.ruleName == "Every task needs specific details")
        #expect(!sheet.canSend)
        sheet.reason = "   "
        #expect(!sheet.canSend)
        await sheet.send()
        #expect(owner.calls.map(\.operation) == [.getTask])
        model.dismissLetThrough()
        #expect(model.letThrough == nil)
        model.askToLetThrough(UUID())
        #expect(model.letThrough == nil, "a check the page does not list opens nothing")
        let passed = Fixtures.check(result: .passed)
        let (other, _, _) = await loaded(storedContractPage(checks: [passed]))
        other.askToLetThrough(passed.id)
        #expect(other.letThrough == nil, "a check that cannot be let through opens nothing")
    }

    @Test("with a reason it sends Override check for that check, and for a failed ready-to-start check then sends Complete contract with the stored contract")
    func letThroughReadyToStart() async throws {
        let check = failedReadyCheck()
        let (model, owner, shared) = await loaded(storedContractPage(checks: [check]))
        model.askToLetThrough(check.id)
        let sheet = try #require(model.letThrough)
        sheet.reason = "The details are in the ticket."
        shared.value = Fixtures.checkedPage(Fixtures.summary(.ready, id: taskID))
        await sheet.send()

        let sent = try exactly(Array(owner.calls.prefix(3)), 3)
        #expect(sent.map(\.operation) == [.getTask, .overrideCheck, .completeContract])
        let override = sent[1]
        #expect(override.path == ["id": check.id.contractString])
        #expect(override.body == .object(["reason": .string("The details are in the ticket.")]))
        let complete = sent[2]
        #expect(complete.path == ["id": taskID.contractString])
        #expect(complete.body?["title"] == .string("Fix the totals"))
        #expect(complete.body?["goal"] == .string("The totals are right."))
        #expect(complete.body?["details"] == .string("For finance."))
        #expect(complete.body?["work_reference"] == .string("~/work/invoices"))
        #expect(complete.body?["minimum_strength_rank"] == .number(2))
        #expect(complete.body?["budget_cap"] != .null)
        #expect(complete.body?["actions"] == .array([]))
        #expect(complete.body?["criteria"]?.arrayValue?.compactMap { $0["text"]?.stringValue } == [
            "Totals match the lines", "An independent reviewer agrees.",
        ])
        #expect(complete.body?["criteria"]?.arrayValue?.compactMap { $0["kind"]?.stringValue } == ["build", "review"])
        #expect(override.key != complete.key)
        #expect(await ShellFixtures.eventually { model.letThrough == nil })
        #expect(await ShellFixtures.eventually { owner.calls.filter { $0.operation == .getTask }.count == 2 })
    }

    @Test("a check at another moment, an errored one, or one on a task that is no longer in Backlog is let through with Override check alone")
    func letThroughAlone() async throws {
        let submit = Fixtures.check(hook: .taskBeforeSubmit, result: .failed, canOverride: true)
        let errored = Fixtures.check(hook: .taskBeforeReady, result: .error, canOverride: true, canRerun: true)
        let readyFailed = Fixtures.check(hook: .taskBeforeReady, result: .failed, canOverride: true)
        for (check, state) in [(submit, TaskState.working), (errored, .backlog), (readyFailed, .ready)] {
            let (model, owner, _) = await loaded(storedContractPage(checks: [check], state: state))
            model.askToLetThrough(check.id)
            let sheet = try #require(model.letThrough)
            sheet.reason = "Fine."
            await sheet.send()
            #expect(owner.calls.map(\.operation).prefix(2) == [.getTask, .overrideCheck], "\(check.hook) \(state)")
            #expect(!owner.calls.map(\.operation).contains(.completeContract), "\(check.hook) \(state)")
        }
    }

    @Test("the row held at the re-run limit is let through with Override check alone, which completes the waiting command in place")
    func letThroughAtTheLimit() async throws {
        let held = Fixtures.check(hook: .taskBeforeSubmit, result: nil, canOverride: true)
        let (model, owner, _) = await loaded(storedContractPage(checks: [held], state: .working))
        model.askToLetThrough(held.id)
        let sheet = try #require(model.letThrough)
        sheet.reason = "Good enough."
        await sheet.send()
        #expect(owner.calls.map(\.operation).prefix(2) == [.getTask, .overrideCheck])
        #expect(!owner.calls.map(\.operation).contains(.completeContract))
    }

    @Test("a send that failed is sent again with the same key; a changed reason gets a new key")
    func letThroughKeys() async throws {
        let check = failedReadyCheck()
        let (model, owner, _) = await loaded(storedContractPage(checks: [check]))
        let attempts = Locked(0)
        owner.script {
            $0.overrideCheck = { _, _, key in
                if attempts.update({ $0 += 1; return $0 }) <= 2 { throw URLError(.cannotConnectToHost) }
                return Fixtures.plain(.overrideCheck, key: key)
            }
        }
        model.askToLetThrough(check.id)
        let sheet = try #require(model.letThrough)
        sheet.reason = "First words."
        await sheet.send()
        #expect(sheet.failure != nil)
        await sheet.send()
        sheet.reason = "Other words."
        await sheet.send()
        let keys = try exactly(owner.calls.filter { $0.operation == .overrideCheck }.map(\.key), 3)
        #expect(keys[0] == keys[1], "the retry is the same command")
        #expect(keys[2] != keys[1], "a changed body is a new command")
    }

    @Test("when the override worked and Complete contract did not, the next press sends only Complete contract, under the same key")
    func letThroughCompleteRetry() async throws {
        let check = failedReadyCheck()
        let (model, owner, _) = await loaded(storedContractPage(checks: [check]))
        let attempts = Locked(0)
        owner.script {
            $0.completeContract = { _, _, key in
                if attempts.update({ $0 += 1; return $0 }) == 1 { throw URLError(.cannotConnectToHost) }
                return Fixtures.plain(.completeContract, key: key)
            }
        }
        model.askToLetThrough(check.id)
        let sheet = try #require(model.letThrough)
        sheet.reason = "Fine."
        await sheet.send()
        #expect(sheet.failure != nil)
        await sheet.send()
        #expect(owner.calls.map(\.operation).filter { $0 != .getTask } == [.overrideCheck, .completeContract, .completeContract])
        let completes = try exactly(owner.calls.filter { $0.operation == .completeContract }, 2)
        #expect(completes[0].key == completes[1].key)
    }

    @Test("a Complete contract that is pending, because a model is checking the details, is taken as sent")
    func letThroughPending() async throws {
        let check = failedReadyCheck()
        let (model, owner, _) = await loaded(storedContractPage(checks: [check]))
        owner.script { $0.completeContract = { _, _, key in .pending(key: key.value, command: .completeContract) } }
        model.askToLetThrough(check.id)
        let sheet = try #require(model.letThrough)
        sheet.reason = "Fine."
        await sheet.send()
        #expect(sheet.failure == nil)
        #expect(await ShellFixtures.eventually { model.letThrough == nil })
    }

    @Test("a refused override is a plain line and the sheet stays open")
    func letThroughRefused() async throws {
        let check = failedReadyCheck()
        let (model, owner, _) = await loaded(storedContractPage(checks: [check]))
        owner.script {
            $0.overrideCheck = { _, _, key in
                .refused(Refusal(code: .invalidState, ruleID: nil, reason: nil), key: key.value, command: .overrideCheck)
            }
        }
        model.askToLetThrough(check.id)
        let sheet = try #require(model.letThrough)
        sheet.reason = "Fine."
        await sheet.send()
        #expect(sheet.failure?.text == "That can't be done to the task as it is now.")
        #expect(model.letThrough != nil)
        #expect(!owner.calls.map(\.operation).contains(.completeContract))
    }

    // MARK: Run it again

    @Test("Run it again sends Rerun check for that check and reads again; a failed one is sent again with the same key, and a new key after it worked")
    func runItAgain() async throws {
        let errored = Fixtures.check(result: .error, canOverride: true, canRerun: true)
        let (model, owner, _) = await loaded(Fixtures.checkedPage(Fixtures.summary(.working, id: taskID), checks: [errored]))
        let attempts = Locked(0)
        owner.script {
            $0.rerunCheck = { _, key in
                if attempts.update({ $0 += 1; return $0 }) == 1 { throw URLError(.cannotConnectToHost) }
                return Fixtures.plain(.rerunCheck, key: key)
            }
        }
        await model.runAgain(errored.id)
        #expect(model.actionFailure != nil)
        await model.runAgain(errored.id)
        await model.runAgain(errored.id)
        let reruns = try exactly(owner.calls.filter { $0.operation == .rerunCheck }, 3)
        #expect(reruns.map(\.path) == Array(repeating: ["id": errored.id.contractString], count: 3))
        #expect(reruns[0].key == reruns[1].key)
        #expect(reruns[2].key != reruns[1].key)
        #expect(owner.calls.filter { $0.operation == .getTask }.count == 3, "one read first, then one after each that worked")
    }

    @Test("Run it again does nothing for a check that cannot be run again")
    func runItAgainGuard() async {
        let passed = Fixtures.check(result: .passed)
        let (model, owner, _) = await loaded(Fixtures.checkedPage(Fixtures.summary(.working, id: taskID), checks: [passed]))
        await model.runAgain(passed.id)
        await model.runAgain(UUID())
        #expect(owner.calls.map(\.operation) == [.getTask])
    }

    // MARK: Draft the details (RD-37)

    @Test("a task in Backlog offers Draft the details until a draft is under way, and again after one was not written")
    func draftStates() async {
        let cases: [(DraftState, Bool, String?)] = [
            (.none, true, nil),
            (.queued, false, "Waiting for an agent to write the details."),
            (.writing, false, "An agent is writing the details."),
            (.notWritten, true, "The details could not be written. Try again, or write them yourself."),
        ]
        for (draft, offered, line) in cases {
            let (model, _, _) = await loaded(Fixtures.checkedPage(Fixtures.summary(.backlog, id: taskID), draft: draft))
            #expect(model.draftState == draft)
            #expect(model.canDraftDetails == offered, "\(draft)")
            #expect(model.draftLine == line, "\(draft)")
            if let line { #expect(BannedTerms.found(in: line).isEmpty) }
        }
    }

    @Test("a task that is not in Backlog, or is being checked, is not offered Draft the details")
    func draftNotOffered() async {
        for state in [TaskState.imaginarium, .ready, .working, .inReview, .done, .cancelled] {
            let (model, _, _) = await loaded(Fixtures.checkedPage(Fixtures.summary(state, id: taskID)))
            #expect(!model.canDraftDetails, "\(state)")
        }
        let pending = PendingState(command: .completeContract, since: Fixtures.pageAsOf)
        let (checking, _, _) = await loaded(Fixtures.checkedPage(Fixtures.summary(.backlog, id: taskID), pending: pending))
        #expect(!checking.canDraftDetails)
    }

    @Test("Draft the details sends Draft contract for this task with no body and reads again; a failed one is sent again with the same key")
    func draftSends() async throws {
        let (model, owner, shared) = await loaded(Fixtures.checkedPage(Fixtures.summary(.backlog, id: taskID)))
        let attempts = Locked(0)
        owner.script {
            $0.draftContract = { _, key in
                if attempts.update({ $0 += 1; return $0 }) == 1 { throw URLError(.cannotConnectToHost) }
                return .completed(DraftContractResult(jobID: UUID()), key: key.value, command: .draftContract)
            }
        }
        await model.draftDetails()
        #expect(model.actionFailure != nil)
        shared.value = Fixtures.checkedPage(Fixtures.summary(.backlog, id: taskID), draft: .queued)
        await model.draftDetails()
        #expect(model.actionFailure == nil)
        let drafts = try exactly(owner.calls.filter { $0.operation == .draftContract }, 2)
        #expect(drafts[0].path == ["id": taskID.contractString])
        #expect(drafts[0].body == nil)
        #expect(drafts[0].key == drafts[1].key)
        #expect(model.draftState == .queued)
        #expect(!model.canDraftDetails)
    }

    // MARK: what the page says while a check runs (RD-27, RD-29)

    @Test("a task whose command is waiting for a check says it is being checked, names the rules, and cannot be sent again")
    func beingChecked() async throws {
        let rule = Fixtures.check(rule: "Every task needs specific details", result: nil)
        let pending = PendingState(command: .completeContract, since: Fixtures.pageAsOf, waitingOnRuleIDs: [rule.ruleID])
        let page = Fixtures.checkedPage(Fixtures.summary(.backlog, id: taskID, title: "Fix the totals"), checks: [rule], pending: pending)
        let (model, _, _) = await loaded(page)
        #expect(model.pendingLine == "Being checked: Every task needs specific details")
        #expect(model.status?.chip?.text == "Checking the details")
        #expect(!model.canSend)
        let quiet = Fixtures.checkedPage(Fixtures.summary(.backlog, id: taskID))
        let (idle, _, _) = await loaded(quiet)
        #expect(idle.pendingLine == nil)
        #expect(idle.status?.chip?.text == "Needs details")
    }

    @Test("a pending command with no name for its rules is just being checked")
    func beingCheckedNoNames() async {
        let pending = PendingState(command: .submit, since: Fixtures.pageAsOf, waitingOnRuleIDs: [UUID()])
        let (model, _, _) = await loaded(Fixtures.checkedPage(Fixtures.summary(.working, id: taskID), pending: pending))
        #expect(model.pendingLine == "Being checked")
        #expect(model.status?.chip?.text == "Being checked")
    }

    @Test("a failed check behind an incomplete contract leaves the page saying Needs details with the reason")
    func needsDetailsWithReason() async {
        let failed = Fixtures.check(hook: .taskBeforeReady, result: .failed, reason: "It does not say who it is for.", canOverride: true)
        let page = Fixtures.checkedPage(
            Fixtures.summary(.backlog, id: taskID), holds: [Fixtures.hold(.contractIncomplete, taskID: taskID)], checks: [failed])
        let (model, _, _) = await loaded(page)
        #expect(model.status?.chip?.text == "Needs details")
        #expect(model.status?.note == "It does not say who it is for.")
    }

    @Test("Send to agents that is pending is not a failure: the page reads again and says it is being checked")
    func sendPending() async {
        let (model, owner, shared) = await loaded(backlogPage())
        owner.script { $0.completeContract = { _, _, key in .pending(key: key.value, command: .completeContract) } }
        shared.value = Fixtures.checkedPage(
            Fixtures.summary(.backlog, id: taskID),
            pending: PendingState(command: .completeContract, since: Fixtures.pageAsOf))
        await model.sendToAgents()
        #expect(model.actionFailure == nil)
        #expect(owner.calls.map(\.operation) == [.getTask, .completeContract, .getTask])
        #expect(model.status?.chip?.text == "Checking the details")
    }

    @Test("the words of the checks, the timing and the draft are in plain words")
    func checkWordsArePlain() async {
        let checks = CheckResult.allCases.map { Fixtures.check(result: $0, canOverride: true, canRerun: true) }
            + [Fixtures.check(result: nil, canOverride: true), Fixtures.check(result: nil)]
        let steps = StepKind.allCases.map { Fixtures.step($0, seconds: 61) }
        let pending = PendingState(command: .completeContract, since: Fixtures.pageAsOf, waitingOnRuleIDs: [checks[0].ruleID])
        let (model, _, _) = await loaded(
            Fixtures.checkedPage(Fixtures.summary(.backlog, id: taskID), steps: steps, checks: checks, pending: pending))
        var words: [String] = model.checks.flatMap {
            [$0.momentText, $0.resultText, $0.wordingText, $0.checkerText, $0.onFailText ?? "", $0.timeText ?? ""]
        }
        words += (model.timing?.rows.map(\.name) ?? []) + [model.pendingLine ?? "", model.timing?.totalText ?? ""]
        words += [model.status?.chip?.text ?? "", model.status?.note ?? ""]
        for word in words { #expect(BannedTerms.found(in: word).isEmpty, "\(word)") }
    }

    // MARK: staying current

    @Test("it reads again when the events tail delivers a batch")
    func readsAgainOnEvents() async {
        let shared = Locked(readyPage(.working))
        let owner = ownerShowing(shared)
        let batches = Locked<[EventsPage]>([])
        owner.script {
            $0.events = { _, _, _ in
                while true {
                    if let page = batches.update({ $0.isEmpty ? nil : $0.removeFirst() }) { return page }
                    try await Task.sleep(for: .milliseconds(2))
                }
            }
        }
        let feed = EventFeed(owner: owner, waitSeconds: 25, retryDelay: .milliseconds(5))
        let model = TaskPageModel(taskID: taskID, api: owner, noteRead: { feed.noteRead(asOfSeq: $0) })
        model.attach(to: feed)
        await model.load()
        #expect(model.state == .loaded)
        #expect(model.status?.statusLine == "Builder One is building")

        shared.value = readyPage(.inReview)
        batches.update { $0.append(EventsPage(events: [ShellFixtures.event(seq: 21)], nextAfterSeq: 21)) }
        #expect(await ShellFixtures.eventually { model.status?.statusLine == "Builder One's work is being reviewed" })
        model.detach()
        feed.stop()
    }
}

@MainActor
@Suite("TaskPage render")
struct TaskPageRenderTests {
    private func draws(_ view: some View) -> Bool {
        let renderer = ImageRenderer(content: view.frame(width: 700, height: 800))
        renderer.scale = 1
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff), let data = bitmap.bitmapData
        else { return false }
        let pixel = max(1, bitmap.bitsPerPixel / 8)
        for row in 0..<bitmap.pixelsHigh {
            let line = data + row * bitmap.bytesPerRow
            for column in 0..<bitmap.pixelsWide {
                let at = line + column * pixel
                for byte in 0..<pixel where at[byte] != data[byte] { return true }
            }
        }
        return false
    }

    @Test("the page draws for a working task, a paused one, a Backlog one, a missing one and a failed read")
    func pageDraws() async {
        let id = UUID()
        func model(_ page: TaskPage) async -> TaskPageModel {
            let owner = FakeOwnerAPI()
            owner.script { $0.task = { _ in page } }
            let model = TaskPageModel(taskID: id, api: owner, noteRead: { _ in })
            await model.load()
            return model
        }
        let events = [Fixtures.event(.taskCreated, seq: 1, taskID: id, actorKind: .owner)]
        let working = Fixtures.page(
            Fixtures.summary(.working, id: id, details: "For finance.", workReference: "~/work"),
            criteria: [Fixtures.criterion("Totals match", taskID: id, evidence: [
                CriterionEvidence(id: UUID(), criterionID: UUID(), kind: .note, value: "Checked"),
            ])], holds: [Fixtures.hold(.roundsExceeded, taskID: id)], events: events)
        let paused = await model(working)
        #expect(draws(TaskPageBody(model: paused)))
        #expect(draws(TaskPageBody(model: paused).environment(\.colorScheme, .dark)))
        paused.askToCancel()
        #expect(draws(TaskPageBody(model: paused)))
        let backlog = await model(Fixtures.page(Fixtures.summary(.backlog, id: id), events: events))
        #expect(draws(TaskPageBody(model: backlog)))
        let missing = TaskPageModel(
            taskID: id, api: { () -> FakeOwnerAPI in
                let owner = FakeOwnerAPI()
                owner.script { $0.task = { _ in throw TransportError(code: .notFound, message: "no") } }
                return owner
            }(), noteRead: { _ in })
        await missing.load()
        #expect(missing.state == .notFound)
        #expect(draws(TaskPageContent(model: missing)))
        let failed = TaskPageModel(taskID: id, api: FakeOwnerAPI(), noteRead: { _ in })
        await failed.load()
        #expect(draws(TaskPageContent(model: failed)))
    }

    @Test("the page draws with its new actions, the editor and a log with a handoff in it, light and dark")
    func handoffDraws() async {
        let id = UUID()
        let hold = Hold(
            id: UUID(), taskID: id, reason: .credentialLimit, credentialID: Fixtures.personalID,
            openedAt: Fixtures.date(19, 9))
        let events = [
            Fixtures.event(.taskCreated, seq: 1, taskID: id, actorKind: .owner),
            Fixtures.event(
                .credentialLimitReached, seq: 2, taskID: id, actorKind: .app, subjectKind: .credential,
                subjectID: Fixtures.personalID, payload: ["window": .string("weekly")]),
        ]
        let page = Fixtures.page(
            Fixtures.summary(.working, id: id, details: "For finance."),
            criteria: [Fixtures.criterion("Totals match", taskID: id)], holds: [hold], events: events,
            names: [LogName(kind: .credential, id: Fixtures.personalID, name: "Personal")])
        let owner = FakeOwnerAPI()
        owner.script {
            $0.task = { _ in page }
            $0.credentials = { Fixtures.credentials([Fixtures.credential(Fixtures.personalID, limitedUntil: Fixtures.date(19, 18))]) }
        }
        let model = TaskPageModel(taskID: id, api: owner, noteRead: { _ in }, clock: Fixtures.clock())
        await model.load()
        #expect(model.canPause && model.canChangeTask)
        #expect(draws(TaskPageBody(model: model)))
        #expect(draws(TaskPageBody(model: model).environment(\.colorScheme, .dark)))
        model.beginEditing()
        let editor = try? #require(model.editor)
        if let editor {
            #expect(draws(EditContractSheet(model: editor, cancel: {})))
            #expect(draws(EditContractSheet(model: editor, cancel: {}).environment(\.colorScheme, .dark)))
        }
        let idea = TaskPageModel(
            taskID: id, api: { () -> FakeOwnerAPI in
                let owner = FakeOwnerAPI()
                owner.script { $0.task = { _ in Fixtures.page(Fixtures.summary(.imaginarium, id: id)) } }
                return owner
            }(), noteRead: { _ in })
        await idea.load()
        #expect(idea.canMoveToBacklog)
        #expect(draws(TaskPageBody(model: idea)))
    }
}
