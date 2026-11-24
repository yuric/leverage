import Foundation
import LeverageKit
import LeverageTestSupport
import SwiftUI
import Testing

@testable import LeverageApp

private typealias Fixtures = TaskScreenFixtures

@MainActor
@Suite("AddTaskModel")
struct AddTaskModelTests {
    private let newTaskID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!

    private func scripted(
        add: (@Sendable (AddTaskRequest, IdempotencyKey) async throws -> CommandOutcome<TaskCreatedResult>)? = nil,
        complete: (@Sendable (UUID, CompleteContractRequest, IdempotencyKey) async throws -> PlainOutcome)? = nil
    ) -> FakeOwnerAPI {
        let id = newTaskID
        let owner = FakeOwnerAPI()
        owner.script {
            $0.addTask = add ?? { _, key in .completed(TaskCreatedResult(taskID: id), key: key.value, command: .addTask) }
            $0.completeContract = complete ?? { _, _, key in Fixtures.plain(.completeContract, key: key) }
        }
        return owner
    }

    private func makeModel(_ owner: FakeOwnerAPI, saved: Locked<Int> = Locked(0)) -> AddTaskModel {
        let model = AddTaskModel(api: owner, onSaved: { saved.update { $0 += 1 } })
        model.title = "Fix the totals on the invoice page"
        model.criteriaText = "Totals match the sum of the lines to the cent\nThe page still loads in a second"
        return model
    }

    // MARK: the form

    @Test("a new form is empty, with normal priority, and cannot be saved without a title")
    func startsEmpty() {
        let model = AddTaskModel(api: FakeOwnerAPI(), onSaved: {})
        #expect(model.title.isEmpty && model.goal.isEmpty && model.criteriaText.isEmpty)
        #expect(model.priority == .normal)
        #expect(model.state == .editing)
        #expect(!model.canSave)
        model.title = "   \n"
        #expect(!model.canSave)
        model.title = "Fix it"
        #expect(model.canSave)
    }

    @Test("saving with no title sends nothing")
    func nothingWithoutTitle() async {
        let owner = scripted()
        let model = AddTaskModel(api: owner, onSaved: {})
        await model.save()
        #expect(owner.calls.isEmpty)
    }

    @Test("Add task starts in the board's project, with No project first in the picker")
    func projectChoices() {
        let first = Project(id: UUID(), name: "Invoices", goal: "Correct totals", briefVersion: 0)
        let second = Project(id: UUID(), name: "Reports", goal: "Useful reports", briefVersion: 0)
        let navigator = Navigator()
        navigator.selectProject(second.id)
        let scoped = AddTaskModel(api: scripted(), boardFilter: navigator.boardFilter, onSaved: {})

        #expect(scoped.projectID == second.id)
        let choices = scoped.projectChoices([first, second])
        #expect(choices.map(\.name) == ["No project", "Invoices", "Reports"])
        #expect(choices.map(\.id) == [nil, first.id, second.id])

        let partial = scoped.projectChoices([first])
        #expect(partial.map(\.name) == ["No project", "Invoices", "Selected project"])
        #expect(partial.map(\.id) == [nil, first.id, second.id])
        #expect(scoped.projectID == second.id)

        navigator.selectProject(nil)
        let all = AddTaskModel(api: scripted(), boardFilter: navigator.boardFilter, onSaved: {})
        #expect(all.projectID == nil)
        #expect(all.projectChoices([]).map(\.name) == ["No project"])
    }

    @Test("the project goes in Add task and both commands keep the outward actions in form order")
    func projectAndActionRequests() async throws {
        let owner = scripted()
        let model = makeModel(owner)
        let projectID = UUID()
        model.projectID = projectID
        model.actions = [
            OutwardActionDraft(kind: .send, description: "Share the approved summary"),
            OutwardActionDraft(kind: .publish, description: "Release the new pricing page"),
            OutwardActionDraft(kind: .pay, description: "Pay the invoice"),
            OutwardActionDraft(kind: .delete, description: "Remove the old draft"),
        ]

        await model.save()

        #expect(owner.calls.map(\.operation) == [.addTask, .completeContract])
        let add = try owner.call(at: 0)
        let complete = try owner.call(at: 1)
        #expect(add.body?["project_id"] == .string(projectID.contractString))
        #expect(complete.body?["project_id"] == nil)
        #expect(add.body?["actions"] == complete.body?["actions"])
        #expect(complete.body?["actions"] == .array([
            .object(["kind": .string("send"), "description": .string("Share the approved summary")]),
            .object(["kind": .string("publish"), "description": .string("Release the new pricing page")]),
            .object(["kind": .string("pay"), "description": .string("Pay the invoice")]),
            .object(["kind": .string("delete"), "description": .string("Remove the old draft")]),
        ]))
    }

    @Test("choosing No project omits the project from the command")
    func noProjectRequest() async throws {
        let owner = scripted()
        let model = AddTaskModel(api: owner, boardFilter: BoardFilter(projectID: UUID()), onSaved: {})
        model.title = "Fix it"
        #expect(model.projectID != nil)
        model.projectID = nil

        await model.save()

        #expect((try owner.call(at: 0)).body?["project_id"] == nil)
    }

    @Test("the action rows can be added, edited and removed, and need a description")
    func editActions() async throws {
        let owner = scripted()
        let model = makeModel(owner)
        model.addAction()
        model.addAction()
        try #require(model.actions.count == 2)
        #expect(model.actions[0].id != model.actions[1].id)
        #expect(model.actions.map(\.kind) == [.publish, .publish])
        model.actions[1].kind = .send
        model.actions[1].description = " \n "
        model.removeAction(id: model.actions[0].id)
        #expect(model.actions.map(\.kind) == [.send])
        #expect(!model.canSave)
        await model.save()
        #expect(owner.calls.isEmpty)

        model.actions[0].description = "  Send the report.  "
        #expect(model.canSave)
        await model.save()
        #expect((try owner.call(at: 1)).body?["actions"] == .array([
            .object(["kind": .string("send"), "description": .string("  Send the report.  ")]),
        ]))
    }

    @Test("the project and action picker use the form's words in picker order")
    func projectAndActionWords() {
        #expect(AddTaskCopy.projectLabel.text == "Project")
        #expect(AddTaskCopy.actionsLabel.text == "What goes out at the end")
        #expect(ActionKind.allCases.map { AddTaskCopy.actionKind($0).text } == [
            "Publish", "Pay", "Send", "Delete",
        ])
    }

    @Test("a project change after Add task failed uses a new key and the chosen project")
    func editedProjectNewKey() async throws {
        let owner = scripted(add: { _, _ in throw URLError(.timedOut) })
        let first = UUID()
        let second = UUID()
        let model = AddTaskModel(api: owner, boardFilter: BoardFilter(projectID: first), onSaved: {})
        model.title = "Fix it"
        await model.save()
        model.projectID = second
        await model.save()

        let initial = try owner.call(at: 0)
        let retry = try owner.call(at: 1)
        #expect(initial.body?["project_id"] == .string(first.contractString))
        #expect(retry.body?["project_id"] == .string(second.contractString))
        #expect(initial.key != retry.key)
    }

    @Test("retry keeps the contract body and key until an action is edited, and keeps the created task's project")
    func retryActions() async throws {
        let attempts = Locked(0)
        let owner = scripted(complete: { _, _, key in
            if attempts.update({ $0 += 1; return $0 }) <= 2 { throw URLError(.networkConnectionLost) }
            return Fixtures.plain(.completeContract, key: key)
        })
        let project = UUID()
        let model = AddTaskModel(api: owner, boardFilter: BoardFilter(projectID: project), onSaved: {})
        model.title = "Fix it"
        model.actions = [OutwardActionDraft(kind: .publish, description: "Release the new pricing page")]

        #expect(model.canChooseProject)
        await model.save()
        #expect(!model.canChooseProject)
        model.projectID = UUID()
        #expect(model.projectID == project)
        await model.save()
        model.actions[0].description = "Release the new pricing page tomorrow"
        await model.save()

        #expect(owner.calls.map(\.operation) == [.addTask, .completeContract, .completeContract, .completeContract])
        let first = try owner.call(at: 1)
        let unchanged = try owner.call(at: 2)
        let changed = try owner.call(at: 3)
        #expect(first.key == unchanged.key && first.body == unchanged.body)
        #expect(first.key != changed.key)
        #expect(first.path == changed.path && changed.path == ["id": newTaskID.contractString])
        #expect(first.body?["actions"] != changed.body?["actions"])
        #expect(changed.body?["actions"] == .array([
            .object(["kind": .string("publish"), "description": .string("Release the new pricing page tomorrow")]),
        ]))
        #expect(model.state == .saved)
    }

    @Test("Save as an idea keeps the chosen project and outward actions")
    func ideaProjectAndActions() async throws {
        let owner = scripted()
        let model = makeModel(owner)
        let project = UUID()
        model.projectID = project
        model.actions = [OutwardActionDraft(kind: .send, description: "Email the summary")]

        await model.saveAsIdea()

        #expect(owner.calls.map(\.operation) == [.addTask])
        let add = try owner.call(at: 0)
        #expect(add.body?["project_id"] == .string(project.contractString))
        #expect(add.body?["actions"] == .array([
            .object(["kind": .string("send"), "description": .string("Email the summary")]),
        ]))
    }

    @Test("editing an action after Add task failed sends the changed body under a new key")
    func editedActionNewAddKey() async throws {
        let owner = scripted(add: { _, _ in throw URLError(.timedOut) })
        let model = makeModel(owner)
        model.actions = [OutwardActionDraft(kind: .publish, description: "Release the new pricing page")]

        await model.save()
        await model.save()
        model.actions[0].kind = .send
        await model.save()

        #expect(owner.calls.map(\.operation) == [.addTask, .addTask, .addTask])
        let first = try owner.call(at: 0)
        let unchanged = try owner.call(at: 1)
        let changed = try owner.call(at: 2)
        #expect(first.key == unchanged.key && first.body == unchanged.body)
        #expect(first.key != changed.key)
        #expect(changed.body?["actions"] == .array([
            .object(["kind": .string("send"), "description": .string("Release the new pricing page")]),
        ]))
    }

    // MARK: the two commands

    @Test("Save task sends Add task and then Complete contract, each with its own key")
    func twoCommands() async {
        let owner = scripted()
        let saved = Locked(0)
        let model = makeModel(owner, saved: saved)
        model.goal = "The totals are right."
        model.details = "For the finance team. Do not change the layout."
        model.priority = .high
        model.workReference = "~/work/invoices"

        await model.save()

        #expect(owner.calls.map(\.operation) == [.addTask, .completeContract])
        let add = owner.calls[0]
        let complete = owner.calls[1]
        #expect(add.key != nil && complete.key != nil && add.key != complete.key)
        #expect(add.body == .object([
            "title": .string("Fix the totals on the invoice page"),
            "goal": .string("The totals are right."),
            "priority": .string("high"),
            "work_reference": .string("~/work/invoices"),
            "state": .string("backlog"),
        ]))
        #expect(complete.path == ["id": newTaskID.contractString])
        #expect(complete.body == .object([
            "title": .string("Fix the totals on the invoice page"),
            "goal": .string("The totals are right."),
            "details": .string("For the finance team. Do not change the layout."),
            "criteria": .array([
                .object(["text": .string("Totals match the sum of the lines to the cent"), "kind": .string("build")]),
                .object(["text": .string("The page still loads in a second"), "kind": .string("build")]),
                .object(["text": .string(AddTaskCopy.reviewCriterion.text), "kind": .string("review")]),
            ]),
            "actions": .array([]),
            "minimum_strength_rank": .null,
            "budget_cap": .null,
            "work_reference": .string("~/work/invoices"),
        ]))
        #expect(model.state == .saved)
        #expect(saved.value == 1)
    }

    @Test("an empty goal is the title, an empty details or work field is null, and blank criteria lines are dropped")
    func defaults() async {
        let owner = scripted()
        let model = AddTaskModel(api: owner, onSaved: {})
        model.title = "  Fix the totals  "
        model.criteriaText = "\n  First  \n\n   \nSecond\n"
        await model.save()

        #expect(owner.calls[0].body?["goal"] == .string("Fix the totals"))
        #expect(owner.calls[0].body?["title"] == .string("Fix the totals"))
        #expect(owner.calls[0].body?["priority"] == .string("normal"))
        #expect(owner.calls[0].body?["work_reference"] == nil)
        let complete = owner.calls[1].body
        #expect(complete?["details"] == .null)
        #expect(complete?["work_reference"] == .null)
        #expect(complete?["criteria"]?.arrayValue?.compactMap { $0["text"]?.stringValue } == [
            "First", "Second", AddTaskCopy.reviewCriterion.text,
        ])
    }

    @Test("with no criteria typed the contract still goes, holding only the independent review")
    func noCriteria() async {
        let owner = scripted()
        let model = AddTaskModel(api: owner, onSaved: {})
        model.title = "Fix it"
        await model.save()
        #expect(owner.calls.map(\.operation) == [.addTask, .completeContract])
        let criteria = owner.calls[1].body?["criteria"]?.arrayValue ?? []
        #expect(criteria.count == 1)
        #expect(criteria.first?["kind"] == .string("review"))
    }

    // MARK: refusals and errors

    @Test("Add task refused keeps the sheet open with a plain line, and sends nothing more")
    func addRefused() async {
        let refusal = Refusal(code: .invalidState, ruleID: nil, reason: "never shown")
        let owner = scripted(add: { _, key in .refused(refusal, key: key.value, command: .addTask) })
        let saved = Locked(0)
        let model = makeModel(owner, saved: saved)
        await model.save()
        #expect(owner.calls.map(\.operation) == [.addTask])
        #expect(model.state == .failed(.refusalInvalidState))
        #expect(!model.savedWithoutContract)
        #expect(saved.value == 0)
        #expect(model.canSave)
    }

    @Test("a work reference the server finds unfit is a plain line")
    func invalidWorkReference() async {
        let owner = scripted(add: { _, _ in throw TransportError(code: .invalid, message: "a sign-in detail") })
        let model = makeModel(owner)
        model.workReference = "https://example.invalid/?token=made-up"
        await model.save()
        #expect(model.state == .failed(.transportInvalid))
    }

    @Test("Retry after the server could not be reached sends the same Add task again with the same key")
    func retryAfterUnreachable() async {
        let attempts = Locked(0)
        let id = newTaskID
        let owner = scripted(add: { _, key in
            if attempts.update({ $0 += 1; return $0 }) == 1 { throw URLError(.cannotConnectToHost) }
            return .completed(TaskCreatedResult(taskID: id), key: key.value, command: .addTask)
        })
        let model = makeModel(owner)
        await model.save()
        #expect(model.state == .failed(.cannotReach))

        await model.save()
        let adds = owner.calls.filter { $0.operation == .addTask }
        #expect(adds.count == 2)
        #expect(adds[0].key == adds[1].key)
        #expect(adds[0].body == adds[1].body)
        #expect(model.state == .saved)
    }

    @Test("changing the form after a failure sends the next Add task under a new key")
    func editedFormNewKey() async {
        let owner = scripted(add: { _, _ in throw URLError(.timedOut) })
        let model = makeModel(owner)
        await model.save()
        model.title = "Fix the totals, and the dates"
        await model.save()
        let adds = owner.calls.filter { $0.operation == .addTask }
        #expect(adds.count == 2)
        #expect(adds[0].key != adds[1].key)
    }

    @Test("when Complete contract fails the task is saved in Backlog, and Retry sends only Complete contract, same key")
    func completeFailsThenRetry() async {
        let attempts = Locked(0)
        let owner = scripted(complete: { _, _, key in
            if attempts.update({ $0 += 1; return $0 }) == 1 { throw URLError(.networkConnectionLost) }
            return Fixtures.plain(.completeContract, key: key)
        })
        let saved = Locked(0)
        let model = makeModel(owner, saved: saved)

        await model.save()
        #expect(model.state == .failed(.cannotReach))
        #expect(model.savedWithoutContract)
        #expect(saved.value == 0)

        await model.save()
        #expect(owner.calls.map(\.operation) == [.addTask, .completeContract, .completeContract])
        let completes = owner.calls.filter { $0.operation == .completeContract }
        #expect(completes[0].key == completes[1].key)
        #expect(completes[0].path == completes[1].path)
        #expect(model.state == .saved)
        #expect(saved.value == 1)
    }

    @Test("editing the form after Complete contract failed sends the new values under a new key to the same task")
    func completeEditedAfterFailure() async {
        let attempts = Locked(0)
        let owner = scripted(complete: { _, _, key in
            if attempts.update({ $0 += 1; return $0 }) == 1 { throw URLError(.networkConnectionLost) }
            return Fixtures.plain(.completeContract, key: key)
        })
        let model = makeModel(owner)
        await model.save()
        model.criteriaText = "Only one thing"
        await model.save()
        let completes = owner.calls.filter { $0.operation == .completeContract }
        #expect(completes[0].key != completes[1].key)
        #expect(completes[1].body?["criteria"]?.arrayValue?.count == 2)
        #expect(owner.calls.filter { $0.operation == .addTask }.count == 1)
    }

    @Test("Complete contract refused after the task was added keeps the task in Backlog and says so")
    func completeRefused() async {
        let refusal = Refusal(code: .invalidState, ruleID: nil, reason: nil)
        let owner = scripted(complete: { _, _, key in .refused(refusal, key: key.value, command: .completeContract) })
        let model = makeModel(owner)
        await model.save()
        #expect(model.state == .failed(.refusalInvalidState))
        #expect(model.savedWithoutContract)
    }

    @Test("a second press while a save is under way does nothing")
    func busyGuard() async {
        let gate = Locked(false)
        let owner = scripted(add: { [newTaskID] _, key in
            while !gate.value { try await Task.sleep(for: .milliseconds(2)) }
            return .completed(TaskCreatedResult(taskID: newTaskID), key: key.value, command: .addTask)
        })
        let model = makeModel(owner)
        let first = Task { await model.save() }
        #expect(await ShellFixtures.eventually { model.isBusy && owner.calls.count == 1 })
        #expect(!model.canSave)
        await model.save()
        #expect(owner.calls.filter { $0.operation == .addTask }.count == 1)
        gate.value = true
        await first.value
        #expect(model.state == .saved)
    }

    @Test("a sign-in that ended while saving shows the sign-in line")
    func signedOut() async {
        let owner = scripted(add: { _, _ in throw TransportError(code: .unauthenticated, message: "no") })
        let model = makeModel(owner)
        await model.save()
        #expect(model.state == .failed(.transportUnauthenticated))
    }

    // MARK: Save as an idea (HM-48)

    @Test("Save as an idea sends Add task alone, with Ideas as its target, and no contract")
    func saveAsIdea() async throws {
        let owner = scripted()
        let saved = Locked(0)
        let model = makeModel(owner, saved: saved)
        model.goal = "Owners get a summary on Monday."
        model.details = "Plain text, no pictures."
        model.priority = .low
        model.workReference = "~/work/mail"

        await model.saveAsIdea()

        #expect(owner.calls.map(\.operation) == [.addTask])
        #expect((try owner.call(at: 0)).body == .object([
            "title": .string("Fix the totals on the invoice page"),
            "goal": .string("Owners get a summary on Monday."),
            "details": .string("Plain text, no pictures."),
            "priority": .string("low"),
            "work_reference": .string("~/work/mail"),
            "state": .string("ideas"),
        ]))
        #expect((try owner.call(at: 0)).key != nil)
        #expect(model.state == .saved)
        #expect(saved.value == 1)
    }

    @Test("an idea with only a title is added with the title as its goal")
    func ideaWithOnlyATitle() async {
        let owner = scripted()
        let model = AddTaskModel(api: owner, onSaved: {})
        model.title = "  Try a weekly summary email "
        #expect(model.canSaveAsIdea)
        await model.saveAsIdea()
        let body = owner.calls.first?.body
        #expect(body?["title"] == .string("Try a weekly summary email"))
        #expect(body?["goal"] == .string("Try a weekly summary email"))
        #expect(body?["details"] == nil)
        #expect(body?["work_reference"] == nil)
        #expect(body?["state"] == .string("ideas"))
    }

    @Test("Save as an idea needs a title, and sends nothing without one")
    func ideaNeedsTitle() async {
        let owner = scripted()
        let model = AddTaskModel(api: owner, onSaved: {})
        #expect(!model.canSaveAsIdea)
        model.title = "  "
        await model.saveAsIdea()
        #expect(owner.calls.isEmpty)
    }

    @Test("the criteria typed are not sent with an idea, and the form says so only when some are typed")
    func ideaDropsCriteria() async throws {
        let owner = scripted()
        let model = makeModel(owner)
        #expect(model.ideaDropsCriteria)
        await model.saveAsIdea()
        #expect((try owner.call(at: 0)).body?["criteria"] == nil)
        let bare = AddTaskModel(api: owner, onSaved: {})
        bare.title = "Only a title"
        #expect(!bare.ideaDropsCriteria)
    }

    @Test("an idea that failed is sent again with the same key, and an edited one under a new key")
    func ideaKeys() async throws {
        let attempts = Locked(0)
        let id = newTaskID
        let owner = scripted(add: { _, key in
            if attempts.update({ $0 += 1; return $0 }) <= 2 { throw URLError(.timedOut) }
            return .completed(TaskCreatedResult(taskID: id), key: key.value, command: .addTask)
        })
        let model = makeModel(owner)
        await model.saveAsIdea()
        #expect(model.state == .failed(.cannotReach))
        #expect(!model.savedWithoutContract)
        await model.saveAsIdea()
        model.title = "A different idea"
        await model.saveAsIdea()
        let keys = owner.calls.map(\.key)
        try #require(keys.count == 3)
        #expect(keys[0] == keys[1])
        #expect(keys[1] != keys[2])
        #expect(model.state == .saved)
    }

    @Test("an idea does not share a key with Save task, because the server refuses one key with two bodies")
    func ideaKeyIsItsOwn() async throws {
        let owner = scripted(add: { _, _ in throw URLError(.timedOut) })
        let model = makeModel(owner)
        await model.saveAsIdea()
        await model.save()
        let keys = owner.calls.map(\.key)
        try #require(keys.count == 2)
        #expect(keys[0] != keys[1])
    }

    @Test("an idea refused is a plain line, and the form stays open")
    func ideaRefused() async {
        let refusal = Refusal(code: .invalidState, ruleID: nil, reason: "never shown")
        let owner = scripted(add: { _, key in .refused(refusal, key: key.value, command: .addTask) })
        let saved = Locked(0)
        let model = makeModel(owner, saved: saved)
        await model.saveAsIdea()
        #expect(model.state == .failed(.refusalInvalidState))
        #expect(saved.value == 0)
        #expect(model.canSaveAsIdea)
    }

    @Test("once Save task has added the task, Save as an idea is off, so no second task is made")
    func ideaOffAfterTaskAdded() async {
        let owner = scripted(complete: { _, _, _ in throw URLError(.networkConnectionLost) })
        let model = makeModel(owner)
        await model.save()
        #expect(model.savedWithoutContract)
        #expect(!model.canSaveAsIdea)
        await model.saveAsIdea()
        #expect(owner.calls.filter { $0.operation == .addTask }.count == 1)
    }

    @Test("the form's two buttons and its note read as the plain words")
    func ideaWords() {
        #expect(AddTaskCopy.saveAsIdea.text == "Save as an idea")
        #expect(AddTaskCopy.save.text == "Save task")
        #expect(AddTaskCopy.ideaKeepsNoCriteria.text == "An idea keeps the title, the goal and the details. Say what done looks like when you move it to Backlog.")
        for copy in [AddTaskCopy.saveAsIdea, .ideaKeepsNoCriteria] {
            #expect(BannedTerms.found(in: copy.text).isEmpty)
        }
    }

    // MARK: the contract draft, shared with the task page

    @Test("the draft turns its text into criteria, with the independent review last")
    func draftCriteria() {
        var draft = ContractDraft()
        draft.criteriaText = "A\n\nB  "
        #expect(draft.criteria.map(\.text) == ["A", "B", AddTaskCopy.reviewCriterion.text])
        #expect(draft.criteria.map(\.kind) == [.build, .build, .review])
        draft.criteriaText = ""
        #expect(draft.criteria.map(\.kind) == [.review])
    }

    // MARK: rule checks (RD-27, RM-3)

    nonisolated private static func rules(acceptance: Bool? = nil, provider: Bool? = nil) -> RulesList {
        var rows: [RuleRow] = []
        if let acceptance { rows.append(Fixtures.ruleRow(key: "acceptance_criteria", name: "Every task needs acceptance criteria", enabled: acceptance)) }
        if let provider { rows.append(Fixtures.ruleRow(key: "different_provider_review", name: "A different provider reviews every task", enabled: provider)) }
        rows.append(Fixtures.ruleRow(key: "specific_details", name: "Every task needs specific details"))
        return RulesList(rules: rows)
    }

    @Test("a save that answers pending closes the sheet: a check is looking at the details")
    func pendingSaveCloses() async {
        let owner = scripted(complete: { _, _, key in .pending(key: key.value, command: .completeContract) })
        let saved = Locked(0)
        let model = makeModel(owner, saved: saved)
        await model.save()
        #expect(model.state == .saved)
        #expect(model.failure == nil)
        #expect(saved.value == 1)
        #expect(owner.calls.map(\.operation) == [.addTask, .completeContract])
    }

    @Test("a save that is refused still keeps the sheet open")
    func refusedSaveStays() async {
        let owner = scripted(complete: { _, _, key in
            .refused(Refusal(code: .invalidState, ruleID: nil, reason: nil), key: key.value, command: .completeContract)
        })
        let saved = Locked(0)
        let model = makeModel(owner, saved: saved)
        await model.save()
        #expect(model.state != .saved)
        #expect(saved.value == 0)
    }

    @Test("before the rules are read the form says what it said in milestone 2")
    func wordsBeforeTheRules() {
        let model = makeModel(scripted())
        #expect(model.criteriaHint.text == "One thing to check on each line.")
        #expect(model.footnote.text == "An agent that did not build it reviews the work before it counts as done.")
    }

    @Test("while the acceptance-criteria rule is on the hint says an empty task waits in Backlog, and while the provider rule is on the footnote says another provider reviews")
    func hintAndFootnoteFollowTheRules() async {
        let owner = scripted()
        owner.script { $0.listRules = { Self.rules(acceptance: true, provider: true) } }
        let model = makeModel(owner)
        await model.loadRules()
        #expect(model.criteriaHint.text == "Leave this empty and the task waits in Backlog until you fill it in.")
        #expect(model.footnote.text == "An agent from another provider reviews the work before it counts as done.")
        #expect(owner.calls.map(\.operation) == [.listRules])
    }

    @Test("with the two rules off the form keeps milestone 2's words")
    func rulesOff() async {
        let owner = scripted()
        owner.script { $0.listRules = { Self.rules(acceptance: false, provider: false) } }
        let model = makeModel(owner)
        await model.loadRules()
        #expect(model.criteriaHint.text == "One thing to check on each line.")
        #expect(model.footnote.text == "An agent that did not build it reviews the work before it counts as done.")
    }

    @Test("each rule decides its own words")
    func rulesApartFromEachOther() async {
        let owner = scripted()
        owner.script { $0.listRules = { Self.rules(acceptance: true, provider: false) } }
        let model = makeModel(owner)
        await model.loadRules()
        #expect(model.criteriaHint.text == "Leave this empty and the task waits in Backlog until you fill it in.")
        #expect(model.footnote.text == "An agent that did not build it reviews the work before it counts as done.")

        let other = scripted()
        other.script { $0.listRules = { Self.rules(acceptance: false, provider: true) } }
        let second = makeModel(other)
        await second.loadRules()
        #expect(second.criteriaHint.text == "One thing to check on each line.")
        #expect(second.footnote.text == "An agent from another provider reviews the work before it counts as done.")
    }

    @Test("a rule the list does not carry counts as off, and a list that cannot be read leaves the words as they were")
    func missingOrUnreadable() async {
        let owner = scripted()
        owner.script { $0.listRules = { Self.rules() } }
        let model = makeModel(owner)
        await model.loadRules()
        #expect(model.criteriaHint.text == "One thing to check on each line.")

        let failing = scripted()
        failing.script { $0.listRules = { throw URLError(.cannotConnectToHost) } }
        let broken = makeModel(failing)
        await broken.loadRules()
        #expect(broken.criteriaHint.text == "One thing to check on each line.")
        #expect(broken.footnote.text == "An agent that did not build it reviews the work before it counts as done.")
        #expect(broken.state == .editing, "the words are a nicety: the form works without them")
    }

    @Test("the rules are read once when the form opens, not again")
    func readOnce() async {
        let owner = scripted()
        owner.script { $0.listRules = { Self.rules(acceptance: true) } }
        let model = makeModel(owner)
        await model.loadRules()
        await model.loadRules()
        #expect(owner.calls.filter { $0.operation == .listRules }.count == 1)
    }
}

@MainActor
@Suite("AddTask render")
struct AddTaskRenderTests {
    private func draws(_ view: some View) -> Bool {
        let renderer = ImageRenderer(content: view.frame(width: 520, height: 700))
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

    @Test("the form draws empty, filled, saving and with a failure showing, light and dark")
    func formDraws() async {
        let empty = AddTaskModel(api: FakeOwnerAPI(), onSaved: {})
        #expect(draws(AddTaskForm(model: empty, cancel: {})))
        #expect(draws(AddTaskFields(model: empty)))
        #expect(draws(AddTaskForm(model: empty, cancel: {}).environment(\.colorScheme, .dark)))
        let failing = AddTaskModel(api: FakeOwnerAPI(), onSaved: {})
        failing.title = "Fix it"
        await failing.save()
        #expect(failing.state != .editing)
        #expect(draws(AddTaskForm(model: failing, cancel: {})))
        let idea = AddTaskModel(api: FakeOwnerAPI(), onSaved: {})
        idea.title = "Fix it"
        idea.criteriaText = "One thing"
        #expect(idea.ideaDropsCriteria)
        #expect(draws(AddTaskForm(model: idea, cancel: {})))
        #expect(draws(AddTaskForm(model: idea, cancel: {}).environment(\.colorScheme, .dark)))
    }
}
