import Foundation
import LeverageKit
import LeverageTestSupport
import Testing

@testable import LeverageApp

@MainActor
@Suite("DecidedModel")
struct DecidedModelTests {
    @Test("Newest decisions appear first with their task, summary, and mark")
    func newestFirst() async throws {
        let old = decision(.question, time: 1, undoable: false)
        let middle = decision(.question, time: 2)
        let recent = decision(.approval, time: 3, state: .started, started: true)
        let owner = owner(Locked([middle, old, recent]))
        let model = DecidedModel(api: owner)

        await model.load()

        #expect(model.rows == [recent, middle, old])
        let row = try #require(model.rows.first)
        #expect(row.taskTitle == recent.taskTitle)
        #expect(row.summary == recent.summary)
        #expect(model.mark(for: row) == "May already have gone out")
        #expect(model.mark(for: middle) == "Can still be undone")
        #expect(model.mark(for: old) == "Cannot be undone")
        model.requestUndo(old)
        #expect(model.confirming == nil)
    }

    @Test("Undoing a question asks for confirmation, then sends the new answer in a second command")
    func replaceAnswer() async throws {
        let original = decision(.question, time: 1, outcome: "Blue.")
        let current = Locked([original])
        let owner = owner(current)
        owner.script { script in
            script.answerQuestion = { _, request, key in
                current.update { $0 = [withdrawn(original, answer: request.answer)] }
                return .completed(nil, key: key.value, command: .answerQuestion)
            }
        }
        let model = DecidedModel(api: owner)
        await model.load()

        model.requestUndo(original)
        #expect(model.confirming == original)
        #expect(commands(owner).isEmpty)
        model.dismissUndo()
        await model.confirmUndo()
        #expect(commands(owner).isEmpty)

        model.requestUndo(original)
        model.answer = "Use green."
        await model.confirmUndo()

        let calls = commands(owner)
        #expect(calls.map(\.operation) == [.overturnAnswer, .answerQuestion])
        #expect(calls.map { $0.path["id"] } == [original.questionID?.contractString, original.questionID?.contractString])
        #expect(calls.last?.body == .object(["answer": .string("Use green.")]))
        #expect(model.confirming == nil)
        let row = try #require(model.rows.first)
        #expect(model.effect(for: row) == "The agent was told. Your answer: Use green.")
    }

    @Test("Withdrawing a question without a replacement sends one command")
    func withdrawAnswer() async throws {
        let original = decision(.question, time: 1, outcome: "Blue.")
        let current = Locked([original])
        let owner = owner(current)
        owner.script { script in
            script.overturnAnswer = { _, key in
                current.update { $0 = [withdrawn(original)] }
                return .completed(nil, key: key.value, command: .overturnAnswer)
            }
        }
        let model = DecidedModel(api: owner)
        await model.load()

        model.requestUndo(original)
        await model.confirmUndo()

        #expect(commands(owner).map(\.operation) == [.overturnAnswer])
        let row = try #require(model.rows.first)
        #expect(model.effect(for: row) == "No new answer yet.")
    }

    @Test("After a failed replacement, retry sends only the answer with the same key")
    func retryReplacement() async throws {
        let original = decision(.question, time: 1, outcome: "Blue.")
        let current = Locked([original])
        let owner = owner(current)
        let attempts = Locked(0)
        owner.script { script in
            script.answerQuestion = { _, request, key in
                let first = attempts.update { count in
                    count += 1
                    return count == 1
                }
                if first { throw URLError(.timedOut) }
                current.update { $0 = [withdrawn(original, answer: request.answer)] }
                return .completed(nil, key: key.value, command: .answerQuestion)
            }
        }
        let model = DecidedModel(api: owner)
        await model.load()
        model.requestUndo(original)
        model.answer = "Green."

        await model.confirmUndo()
        #expect(model.confirming == original)
        #expect(model.answer == "Green.")
        await model.confirmUndo()

        let calls = commands(owner)
        #expect(calls.map(\.operation) == [.overturnAnswer, .answerQuestion, .answerQuestion])
        let answers = calls.filter { $0.operation == .answerQuestion }
        #expect(Set(answers.compactMap { $0.key?.value }).count == 1)
        #expect(model.confirming == nil)
        let row = try #require(model.rows.first)
        #expect(model.effect(for: row) == "The agent was told. Your answer: Green.")
    }

    @Test("Approval confirmation shows what the server recorded, including a concurrent completion")
    func approvalEffects() async throws {
        for effect: DecisionOverturnEffect in [.stopped, .recordedOnly] {
            let original = decision(.approval, time: 1, state: .started, started: true)
            let current = Locked([original])
            let owner = owner(current)
            owner.script { script in
                script.overturnApproval = { _, key in
                    current.update {
                        $0 = [Decision(
                            actionID: original.actionID, decidedAt: original.decidedAt, undoable: false,
                            kind: .approval, taskID: original.taskID, taskTitle: original.taskTitle,
                            seatID: original.seatID, summary: original.summary,
                            actionState: effect == .stopped ? .stopped : .done, started: true,
                            overturnedAt: Date(timeIntervalSince1970: 2), overturnEffect: effect)]
                    }
                    return .completed(nil, key: key.value, command: .overturnApproval)
                }
            }
            let model = DecidedModel(api: owner)
            await model.load()

            model.requestUndo(original)
            #expect(model.confirming == original)
            #expect(commands(owner).isEmpty)
            await model.confirmUndo()

            let calls = commands(owner)
            #expect(calls.map(\.operation) == [.overturnApproval])
            #expect(calls.first?.path["id"] == original.actionID?.contractString)
            let row = try #require(model.rows.first)
            #expect(model.effect(for: row) == (effect == .stopped
                    ? "Stopped. See Needs you."
                    : "Recorded. Publishing had already happened, so nothing changed."))
        }
    }

    @Test("a decision event refreshes the list through the shared event feed")
    func followsDecisions() async {
        let owner = FakeOwnerAPI()
        let read = Locked<[Decision]>([])
        let events = Locked<[EventRecord]>([])
        owner.script {
            $0.board = { TaskScreenFixtures.board([], asOfSeq: 30) }
            $0.listDecisions = { DecisionsList(decisions: read.value) }
            $0.events = { _, _, _ in
                while true {
                    if let event = events.update({ $0.isEmpty ? nil : $0.removeFirst() }) {
                        return EventsPage(events: [event], nextAfterSeq: event.seq)
                    }
                    try await Task.sleep(for: .milliseconds(2))
                }
            }
        }
        let feed = EventFeed(owner: owner)
        let model = DecidedModel(api: owner)
        let watcher = Task { await model.watch(using: feed) }
        defer {
            watcher.cancel()
            feed.stop()
        }
        #expect(await ShellFixtures.eventually { model.state == .loaded })
        let decision = Decision(
            questionID: UUID(), decidedAt: Date(), undoable: true, kind: .question, taskID: UUID(),
            taskTitle: "Correct the totals", seatID: UUID(), summary: "Which label?", outcome: "Blue")
        read.value = [decision]
        events.value = [TaskScreenFixtures.event(.questionAnswered, seq: 31, taskID: decision.taskID)]
        #expect(await ShellFixtures.eventually { model.rows.first == decision })
    }

    @Test("A completed approval can be recorded once while remaining marked as irreversible")
    func recordObjection() async throws {
        let done = decision(.approval, time: 1, undoable: false, state: .done, started: true)
        let closed = decision(.approval, time: 2, undoable: false, state: .stopped)
        let cancelled = decision(.approval, time: 3, undoable: false, state: .done)
        let current = Locked([done, closed, cancelled])
        let owner = owner(current)
        owner.script { script in
            script.board = {
                TaskScreenFixtures.board([
                    TaskScreenFixtures.boardTask(.done, id: done.taskID),
                    TaskScreenFixtures.boardTask(.cancelled, id: cancelled.taskID),
                ])
            }
            script.overturnApproval = { _, key in
                current.value = [Decision(
                    actionID: done.actionID, decidedAt: done.decidedAt, undoable: false, kind: .approval,
                    taskID: done.taskID, taskTitle: done.taskTitle, seatID: done.seatID, summary: done.summary,
                    actionState: .done, started: true, overturnedAt: Date(timeIntervalSince1970: 3),
                    overturnEffect: .recordedOnly), closed, cancelled]
                return .completed(nil, key: key.value, command: .overturnApproval)
            }
        }
        let model = DecidedModel(api: owner)
        await model.load()

        #expect(model.mark(for: done) == "Cannot be undone")
        #expect(!model.canUndo(done))
        #expect(model.canRecordObjection(done))
        #expect(!model.canUndo(closed))
        #expect(!model.canRecordObjection(closed))
        #expect(!model.canRecordObjection(cancelled))
        model.requestUndo(cancelled)
        #expect(model.confirming == nil)
        model.requestUndo(closed)
        #expect(model.confirming == nil)

        model.requestUndo(done)
        #expect(model.confirming == done)
        #expect(commands(owner).isEmpty)
        await model.confirmUndo()

        #expect(commands(owner).map(\.operation) == [.overturnApproval])
        let recorded = try #require(model.rows.first { $0.actionID == done.actionID })
        #expect(!model.canRecordObjection(recorded))
        #expect(model.effect(for: recorded) == "Recorded. Publishing had already happened, so nothing changed.")
    }

    @Test("A superseded approval has its own row and cannot undo the current approval")
    func supersededApprovalCannotUndoCurrentApproval() async {
        let latest = decision(.approval, time: 2, state: .approved)
        let older = decision(
            .approval, time: 1, undoable: false, state: .approved, actionID: latest.actionID, taskID: latest.taskID)
        let owner = owner(Locked([older, latest]))
        let model = DecidedModel(api: owner)
        await model.load()

        #expect(model.rows == [latest, older])
        #expect(older.decidedRowID != latest.decidedRowID)
        model.requestUndo(older)
        #expect(model.confirming == nil)
        await model.confirmUndo()
        #expect(commands(owner).isEmpty)

        model.dismissUndo()
        model.requestUndo(latest)
        #expect(model.confirming == latest)
    }

    @Test("Only the latest approval of a completed action can record an objection")
    func recordObjectionOnlyForLatestApproval() async {
        let latest = decision(.approval, time: 2, undoable: false, state: .done, started: true)
        let older = decision(
            .approval, time: 1, undoable: false, state: .done, actionID: latest.actionID, taskID: latest.taskID)
        let owner = owner(Locked([older, latest]))
        owner.script { script in
            script.board = { TaskScreenFixtures.board([TaskScreenFixtures.boardTask(.done, id: latest.taskID)]) }
        }
        let model = DecidedModel(api: owner)
        await model.load()

        #expect(!model.canRecordObjection(older))
        #expect(model.canRecordObjection(latest))
        model.requestUndo(older)
        #expect(model.confirming == nil)
        await model.confirmUndo()
        #expect(commands(owner).isEmpty)

        model.dismissUndo()
        model.requestUndo(latest)
        #expect(model.confirming == latest)
    }

    private func owner(_ decisions: Locked<[Decision]>) -> FakeOwnerAPI {
        let owner = FakeOwnerAPI()
        owner.script { script in
            script.listDecisions = { DecisionsList(decisions: decisions.value) }
            script.overturnAnswer = { _, key in
                .completed(nil, key: key.value, command: .overturnAnswer)
            }
        }
        return owner
    }

    private func commands(_ owner: FakeOwnerAPI) -> [FakeCall] {
        owner.calls.filter { [.overturnAnswer, .answerQuestion, .overturnApproval].contains($0.operation) }
    }

    private func decision(
        _ kind: DecisionKind, time: TimeInterval, undoable: Bool = true,
        outcome: String? = nil, state: ActionState? = nil, started: Bool = false,
        actionID: UUID? = nil, taskID: UUID = UUID()
    ) -> Decision {
        Decision(
            questionID: kind == .question ? UUID() : nil, actionID: kind == .approval ? actionID ?? UUID() : nil,
            decidedAt: Date(timeIntervalSince1970: time), undoable: undoable, kind: kind,
            taskID: taskID, taskTitle: "Fix the invoice", seatID: UUID(),
            summary: kind == .approval ? "Publish the invoice" : "Which label goes on the invoice?",
            outcome: outcome, actionState: state, started: started)
    }
}

private func withdrawn(_ original: Decision, answer: String? = nil) -> Decision {
    Decision(
        questionID: original.questionID, decidedAt: original.decidedAt, undoable: false, kind: .question,
        taskID: original.taskID, taskTitle: original.taskTitle, seatID: original.seatID, summary: original.summary,
        outcome: answer, overturnedAt: Date(timeIntervalSince1970: 2), overturnEffect: .answerWithdrawn)
}
