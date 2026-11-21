import Foundation
import LeverageKit
import LeverageTestSupport
import Testing

@testable import LeverageApp

@MainActor
@Suite("Task page questions and approvals")
struct TaskPageQuestionsApprovalsTests {
    private let taskID = UUID()
    private let agentID = UUID()

    private func page(
        _ state: TaskState, actions: [OutwardAction] = [], questions: [Question] = [],
        events: [EventRecord] = [], started: Bool = false
    ) -> TaskPage {
        TaskPage(
            task: TaskSummary(id: taskID, title: "Prepare the preview", goal: "Check the changes", state: state),
            actions: actions, questions: questions, events: events,
            names: [LogName(kind: .seat, id: agentID, name: "Example agent")],
            reviewerSeatExists: true, asOfSeq: 10, anyActionStarted: started)
    }

    private func loaded(_ page: TaskPage) async -> (TaskPageModel, FakeOwnerAPI) {
        let owner = FakeOwnerAPI()
        owner.script { $0.task = { _ in page } }
        let model = TaskPageModel(taskID: taskID, api: owner, noteRead: { _ in })
        await model.load()
        return (model, owner)
    }

    @Test("Questions name the asker and who answered, with no answer shown before one exists")
    func questions() async throws {
        let answered = Question(
            id: UUID(), taskID: taskID, askingSeatID: agentID, text: "Which preview?",
            assumption: "Use the first", blocking: false, outcome: .answered, answer: "Use the second",
            basis: .owner, answeredByKind: .owner)
        let fromSeat = Question(
            id: UUID(), taskID: taskID, askingSeatID: agentID, text: "Which folder?",
            assumption: "", blocking: true, outcome: .answered, answer: "The preview folder",
            basis: .record, answeredByKind: .seat, answeredByID: agentID)
        let waiting = Question(
            id: UUID(), taskID: taskID, askingSeatID: agentID, text: "Which heading?",
            assumption: "", blocking: true, outcome: .open)
        let (model, _) = await loaded(page(.working, questions: [answered, fromSeat, waiting]))
        #expect(model.questions.map(\.question) == ["Which preview?", "Which folder?", "Which heading?"])
        #expect(model.questions.map(\.askedBy) == ["Example agent", "Example agent", "Example agent"])
        #expect(model.questions.map(\.answer) == ["Use the second", "The preview folder", nil])
        #expect(model.questions.map(\.answerBy) == ["You", "Example agent", nil])
    }

    @Test("What goes out is listed in contract order, with the state and the approver")
    func actions() async {
        let expected = ["Not yet asked", "Being checked", "Approved", "Started", "Stopped", "Skipped", "Cancelled", "Done"]
        let actions = ActionState.allCases.enumerated().map { index, state in
            OutwardAction(
                id: UUID(), taskID: taskID, kind: .publish, description: "Example preview", state: state,
                approvedByKind: state == .approved ? .seat : nil, approvedByID: agentID, position: index)
        }
        let (model, _) = await loaded(page(.finishing, actions: actions.reversed()))
        #expect(model.actions.map(\.id) == actions.map(\.id))
        #expect(model.actions.map(\.state) == expected)
        #expect(model.actions.first(where: { $0.id == actions.first(where: { $0.state == .approved })?.id })?.approvedBy
            == "Example agent")
        #expect(model.actions.first?.kind == "Publish")
        #expect(model.actions.first?.description == "Example preview")
    }

    @Test("Cancel adds the warning if the server says an action started, including when it no longer shows Started")
    func cancelWarning() async {
        let action = OutwardAction(
            id: UUID(), taskID: taskID, kind: .send, description: "Example draft", state: .stopped)
        let (started, _) = await loaded(page(.finishing, actions: [action], started: true))
        let (unstarted, _) = await loaded(page(.finishing, actions: [action]))
        #expect(unstarted.cancelExplanation == "Any agent working on it stops. This can't be undone.")
        #expect(started.cancelExplanation == unstarted.cancelExplanation + "\n\nAn action may already have gone out.")
    }

    @Test("Delete content is offered for Done and Cancelled until deleted, then reads the remaining record")
    func deleteContent() async {
        #expect(TaskPageCopy.deleteContentExplanation.text.contains("Backups"))
        for state in TaskState.allCases {
            let (model, owner) = await loaded(page(state))
            let finished = state == .done || state == .cancelled
            #expect(model.canDeleteContent == finished)
            model.askToDeleteContent()
            #expect(model.isConfirmingDeleteContent == finished)
            #expect(owner.calls.map(\.operation) == [.getTask])
            if !finished {
                await model.confirmDeleteContent()
                #expect(owner.calls.map(\.operation) == [.getTask])
            }
            if finished {
                let event = EventRecord(
                    id: UUID(), workspaceID: UUID(), seq: 10, at: Date(timeIntervalSince1970: 0), type: .contentDeleted,
                    actorKind: .owner, taskID: taskID)
                let deleted = page(state, events: [event])
                owner.script {
                    $0.deleteTaskContent = { _, key in TaskScreenFixtures.plain(.deleteContent, key: key) }
                    $0.task = { _ in deleted }
                }
                await model.confirmDeleteContent()
                #expect(owner.calls.map(\.operation) == [.getTask, .deleteTaskContent, .getTask])
                #expect(owner.calls.first(where: { $0.operation == .deleteTaskContent })?.path == ["id": taskID.contractString])
                #expect(!model.canDeleteContent)
                #expect(model.title == "Deleted task")
            }
        }
    }

    @Test("Sending the Backlog contract again keeps the stored actions, spending limit, and strength")
    func resendContract() async {
        let task = TaskSummary(
            id: taskID, title: "Prepare the preview", goal: "Check the changes", state: .backlog,
            minimumStrengthRank: 2, budgetCap: 15)
        let action = OutwardAction(
            id: UUID(), taskID: taskID, kind: .send, description: "Example draft", state: .contracted)
        let read = TaskPage(task: task, actions: [action], reviewerSeatExists: true, asOfSeq: 10)
        let (model, owner) = await loaded(read)
        owner.script { $0.completeContract = { _, _, key in TaskScreenFixtures.plain(.completeContract, key: key) } }
        await model.sendToAgents()
        let body = owner.calls.first(where: { $0.operation == .completeContract })?.body
        #expect(body?["actions"]?.arrayValue?.first?["description"] == .string("Example draft"))
        #expect(body?["minimum_strength_rank"] == .number(2))
        #expect(body?["budget_cap"] == .number(15))
    }
}

@MainActor
@Suite("Task settings")
struct TaskSettingsModelTests {
    private let task = TaskSummary(
        id: UUID(), projectID: UUID(), title: "Prepare the preview", goal: "Check the changes", state: .working,
        budgetCap: 12.5, priority: .normal)

    private func configuredOwner() -> FakeOwnerAPI {
        let owner = FakeOwnerAPI()
        owner.script {
            $0.changeTaskPriority = { _, _, key in TaskScreenFixtures.plain(.changeTaskPriority, key: key) }
            $0.changeTaskProject = { _, _, key in TaskScreenFixtures.plain(.changeTaskProject, key: key) }
            $0.changeTaskCap = { _, _, key in TaskScreenFixtures.plain(.changeTaskCap, key: key) }
        }
        return owner
    }

    @Test("The sheet sends only the changed fields, with null to clear the project or the spending limit")
    func changedFields() async {
        let owner = configuredOwner()
        var updates = 0
        let model = TaskSettingsModel(task: task, api: owner, locale: Locale(identifier: "en_US"), didChange: { updates += 1 })
        #expect(model.capText == "12.50")
        #expect(!model.canSave)
        _ = await model.save()
        #expect(owner.calls.isEmpty)
        model.priority = .high
        #expect(model.canSave)
        #expect(await model.save())
        #expect(owner.calls.map(\.operation) == [.changeTaskPriority])
        #expect(owner.calls.last?.body == .object(["priority": .string("high")]))
        model.projectID = nil
        #expect(await model.save())
        #expect(owner.calls.map(\.operation) == [.changeTaskPriority, .changeTaskProject])
        #expect(owner.calls.last?.body == .object(["project_id": .null]))
        model.capText = ""
        #expect(await model.save())
        #expect(owner.calls.map(\.operation) == [.changeTaskPriority, .changeTaskProject, .changeTaskCap])
        #expect(owner.calls.last?.body == .object(["budget_cap": .null]))
        #expect(owner.calls.allSatisfy { $0.path == ["id": task.id.contractString] })
        #expect(updates == 3)
        #expect(!model.canSave)
    }

    @Test("Spending limit validates a dollar amount before sending it")
    func validatesCap() async {
        let owner = configuredOwner()
        let model = TaskSettingsModel(task: task, api: owner, locale: Locale(identifier: "en_US"), didChange: {})
        for bad in ["-12.00", "5.0001", "12x", "1e2", "100000000.00"] {
            model.capText = bad
            #expect(!model.canSave)
            #expect(!(await model.save()))
        }
        #expect(owner.calls.isEmpty)
        model.capText = "12.5"
        #expect(!model.canSave)
        model.capText = "10.25"
        #expect(await model.save())
        #expect(owner.calls.last?.body == .object(["budget_cap": .number(10.25)]))
    }

    @Test("Task spending limits show and take amounts in the Mac’s number format")
    func localizedCap() async {
        let owner = configuredOwner()
        let model = TaskSettingsModel(task: task, api: owner, locale: Locale(identifier: "de_DE"), didChange: {})
        #expect(model.capText == "12,50")
        #expect(!model.canSave)
        model.capText = "13,25"
        #expect(await model.save())
        #expect(owner.calls.last?.body == .object(["budget_cap": .number(13.25)]))
    }

    @Test("After an unanswered second command a retry skips the first and retains the second key")
    func retriesUnansweredChange() async throws {
        let owner = configuredOwner()
        owner.script { $0.changeTaskProject = { _, _, _ in throw URLError(.timedOut) } }
        var updates = 0
        let model = TaskSettingsModel(task: task, api: owner, locale: Locale(identifier: "en_US"), didChange: { updates += 1 })
        model.priority = .high
        model.projectID = nil
        model.capText = "40"
        #expect(!(await model.save()))
        #expect(updates == 1)
        owner.script {
            $0.changeTaskProject = { _, _, key in TaskScreenFixtures.plain(.changeTaskProject, key: key) }
        }
        #expect(await model.save())
        #expect(owner.calls.map(\.operation) == [.changeTaskPriority, .changeTaskProject, .changeTaskProject, .changeTaskCap])
        let retries = owner.calls.filter { $0.operation == .changeTaskProject }
        try #require(retries.count == 2)
        #expect(retries[0].key != nil)
        #expect(retries[0].key == retries[1].key)
        #expect(updates == 2)
    }
}
