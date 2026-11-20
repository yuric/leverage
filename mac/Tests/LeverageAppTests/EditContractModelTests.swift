import Foundation
import LeverageKit
import LeverageTestSupport
import SwiftUI
import Testing

@testable import LeverageApp

private typealias Fixtures = TaskScreenFixtures

/// The contract editor of a task that already has a contract (HM-49, HE-25).
@MainActor
@Suite("EditContractModel")
struct EditContractModelTests {
    private let taskID = UUID(uuidString: "77777777-7777-4777-8777-777777777777")!
    private let firstID = UUID()
    private let secondID = UUID()
    private let reviewID = UUID()

    private func page(_ state: TaskState = .working) -> TaskPage {
        Fixtures.page(
            Fixtures.summary(
                state, id: taskID, title: "Fix the totals", goal: "The totals are right.", details: "For finance.",
                workReference: "~/work/invoices", priority: .high),
            criteria: [
                Fixtures.criterion("Totals match the lines", taskID: taskID, state: .passed, id: firstID),
                Fixtures.criterion("The page still loads", taskID: taskID, position: 2, id: secondID),
                Fixtures.criterion("A reviewer who did not build it agrees", taskID: taskID, position: 3, kind: .review, id: reviewID),
            ])
    }

    private func owner(
        edit: (@Sendable (UUID, CompleteContractRequest, IdempotencyKey) async throws -> PlainOutcome)? = nil,
        complete: (@Sendable (UUID, CompleteContractRequest, IdempotencyKey) async throws -> PlainOutcome)? = nil
    ) -> FakeOwnerAPI {
        let owner = FakeOwnerAPI()
        owner.script {
            $0.editContract = edit ?? { _, _, key in Fixtures.plain(.editContract, key: key) }
            $0.completeContract = complete ?? { _, _, key in Fixtures.plain(.completeContract, key: key) }
        }
        return owner
    }

    private func make(
        _ owner: FakeOwnerAPI, state: TaskState = .working, saved: Locked<Int> = Locked(0)
    ) -> EditContractModel {
        EditContractModel(page: page(state), api: owner, onSaved: { saved.update { $0 += 1 } })
    }

    // MARK: filled in

    @Test("the editor starts with the task's own title, goal, details, work and criteria in order")
    func filledIn() {
        let model = make(owner())
        #expect(model.draft.title == "Fix the totals")
        #expect(model.draft.goal == "The totals are right.")
        #expect(model.draft.details == "For finance.")
        #expect(model.draft.workReference == "~/work/invoices")
        #expect(model.draft.criteriaText == "Totals match the lines\nThe page still loads")
        #expect(model.state == .editing)
        #expect(model.canSave)
    }

    @Test("from Ready, Working and In review it first says what Save does, and from Backlog it says nothing")
    func warning() {
        for state in [TaskState.ready, .working, .inReview] {
            #expect(make(owner(), state: state).warning == .editWarning, "\(state)")
        }
        #expect(make(owner(), state: .backlog).warning == nil)
        #expect(AddTaskCopy.editWarning.text
            == "The agent stops and the task goes back to Backlog. What has passed stays passed if you leave it as it is.")
    }

    // MARK: Save

    @Test("Save sends Edit contract alone for this task, with every field of the form, and tells the page when it worked")
    func save() async throws {
        let owner = owner()
        let saved = Locked(0)
        let model = make(owner, saved: saved)
        model.draft.title = "Fix the totals, all of them"
        await model.save()

        #expect(owner.calls.map(\.operation) == [.editContract])
        let call = (try owner.call(at: 0))
        #expect(call.path == ["id": taskID.contractString])
        #expect(call.key != nil)
        #expect(call.body == .object([
            "title": .string("Fix the totals, all of them"),
            "goal": .string("The totals are right."),
            "details": .string("For finance."),
            "criteria": .array([
                .object(["text": .string("Totals match the lines"), "kind": .string("build")]),
                .object(["text": .string("The page still loads"), "kind": .string("build")]),
                .object(["text": .string("A reviewer who did not build it agrees"), "kind": .string("review")]),
            ]),
            "actions": .array([]),
            "minimum_strength_rank": .null,
            "budget_cap": .null,
            "work_reference": .string("~/work/invoices"),
        ]))
        #expect(model.state == .saved)
        #expect(saved.value == 1)
    }

    @Test("criteria left as they were are sent with their text untouched, the review one with its own words")
    func unchangedCriteria() async throws {
        let owner = owner()
        let model = make(owner)
        await model.save()
        let sent = (try owner.call(at: 0)).body?["criteria"]?.arrayValue?.compactMap { $0["text"]?.stringValue }
        #expect(sent == ["Totals match the lines", "The page still loads", "A reviewer who did not build it agrees"])
    }

    @Test("a criterion the owner changes or adds is sent as typed, and one taken out is not sent")
    func changedCriteria() async throws {
        let owner = owner()
        let model = make(owner)
        model.draft.criteriaText = "Totals match the lines\nThe page loads in a second\nDates are in order"
        await model.save()
        let sent = (try owner.call(at: 0)).body?["criteria"]?.arrayValue?.compactMap { $0["text"]?.stringValue }
        #expect(sent == [
            "Totals match the lines", "The page loads in a second", "Dates are in order",
            "A reviewer who did not build it agrees",
        ])
    }

    @Test("a task with no review criterion gets the independent review, last, as Add task gives one")
    func reviewCriterionAdded() async throws {
        let bare = Fixtures.page(
            Fixtures.summary(.ready, id: taskID, title: "Fix it"),
            criteria: [Fixtures.criterion("One thing", taskID: taskID)])
        let owner = owner()
        let model = EditContractModel(page: bare, api: owner, onSaved: {})
        await model.save()
        let criteria = (try owner.call(at: 0)).body?["criteria"]?.arrayValue ?? []
        #expect(criteria.last?["kind"] == .string("review"))
        #expect(criteria.last?["text"] == .string(AddTaskCopy.reviewCriterion.text))
    }

    // MARK: Save and send to agents

    @Test("Save and send to agents sends Edit contract and then Complete contract, each under its own key")
    func saveAndSend() async throws {
        let owner = owner()
        let saved = Locked(0)
        let model = make(owner, saved: saved)
        await model.saveAndSend()

        #expect(owner.calls.map(\.operation) == [.editContract, .completeContract])
        #expect((try owner.call(at: 0)).path == ["id": taskID.contractString])
        #expect((try owner.call(at: 1)).path == ["id": taskID.contractString])
        #expect((try owner.call(at: 0)).key != (try owner.call(at: 1)).key)
        #expect((try owner.call(at: 0)).body == (try owner.call(at: 1)).body)
        #expect(model.state == .saved)
        #expect(saved.value == 1)
    }

    @Test("when Complete contract fails the edit stays saved, and Retry sends only Complete contract, same key")
    func completeFails() async throws {
        let attempts = Locked(0)
        let owner = owner(complete: { _, _, key in
            if attempts.update({ $0 += 1; return $0 }) == 1 { throw URLError(.networkConnectionLost) }
            return Fixtures.plain(.completeContract, key: key)
        })
        let saved = Locked(0)
        let model = make(owner, saved: saved)
        await model.saveAndSend()
        #expect(model.state == .failed(.cannotReach))
        #expect(model.savedWithoutSending)
        #expect(saved.value == 0)

        await model.saveAndSend()
        #expect(owner.calls.map(\.operation) == [.editContract, .completeContract, .completeContract])
        let completes = owner.calls.filter { $0.operation == .completeContract }
        try #require(completes.count == 2)
        #expect(completes[0].key == completes[1].key)
        #expect(model.state == .saved)
        #expect(saved.value == 1)
    }

    @Test("an edit refused sends nothing more and says so in plain words")
    func editRefused() async {
        let refusal = Refusal(code: .invalidState, ruleID: nil, reason: "never shown")
        let owner = owner(edit: { _, _, key in .refused(refusal, key: key.value, command: .editContract) })
        let saved = Locked(0)
        let model = make(owner, saved: saved)
        await model.saveAndSend()
        #expect(owner.calls.map(\.operation) == [.editContract])
        #expect(model.state == .failed(.refusalInvalidState))
        #expect(!model.savedWithoutSending)
        #expect(saved.value == 0)
        #expect(model.canSave)
    }

    // MARK: keys, busy, title

    @Test("a Save that failed is sent again with the same key, and an edited form gets a new one")
    func keys() async throws {
        let attempts = Locked(0)
        let owner = owner(edit: { _, _, key in
            if attempts.update({ $0 += 1; return $0 }) <= 2 { throw URLError(.timedOut) }
            return Fixtures.plain(.editContract, key: key)
        })
        let model = make(owner)
        await model.save()
        await model.save()
        model.draft.title = "Another title"
        await model.save()
        let keys = owner.calls.map(\.key)
        try #require(keys.count == 3)
        #expect(keys[0] == keys[1])
        #expect(keys[1] != keys[2])
        #expect(model.state == .saved)
    }

    @Test("a form with no title cannot be saved, and sends nothing")
    func needsTitle() async {
        let owner = owner()
        let model = make(owner)
        model.draft.title = "   "
        #expect(!model.canSave)
        await model.save()
        await model.saveAndSend()
        #expect(owner.calls.isEmpty)
    }

    @Test("a second press while a save is under way does nothing")
    func busyGuard() async {
        let gate = Locked(false)
        let owner = owner(edit: { _, _, key in
            while !gate.value { try await Task.sleep(for: .milliseconds(2)) }
            return Fixtures.plain(.editContract, key: key)
        })
        let model = make(owner)
        let first = Task { await model.save() }
        #expect(await ShellFixtures.eventually { model.isBusy && owner.calls.count == 1 })
        #expect(!model.canSave)
        await model.save()
        #expect(owner.calls.count == 1)
        gate.value = true
        await first.value
        #expect(model.state == .saved)
    }

    @Test("a sign-in that ended while saving shows the sign-in line")
    func signedOut() async {
        let owner = owner(edit: { _, _, _ in throw TransportError(code: .unauthenticated, message: "no") })
        let model = make(owner)
        await model.save()
        #expect(model.state == .failed(.transportUnauthenticated))
    }

    @Test("the editor's words are the ones HM-49 gives, and use no banned word")
    func words() {
        #expect(AddTaskCopy.saveChanges.text == "Save")
        #expect(AddTaskCopy.saveAndSend.text == "Save and send to agents")
        #expect(AddTaskCopy.changeTaskTitle.text == "Change the task")
        #expect(TaskPageCopy.changeTask.text == "Change the task")
        for copy in [AddTaskCopy.saveChanges, .saveAndSend, .changeTaskTitle, .editWarning] {
            #expect(BannedTerms.found(in: copy.text).isEmpty, "\(copy.text)")
        }
    }
}
