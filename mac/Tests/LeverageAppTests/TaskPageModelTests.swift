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
}
