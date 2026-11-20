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
    }
}
