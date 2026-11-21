import Foundation
import LeverageKit
import LeverageTestSupport
import Testing

@testable import LeverageApp

/// The sheet that adds and changes a rule (RD-4, RD-6, RD-21, RD-22, RD-24,
/// WP16): Save sends every field with the unedited ones as they were.
@MainActor
@Suite("RuleEditorModel")
struct RuleEditorModelTests {
    private typealias Fixtures = RulesFixtures

    private struct Rig {
        let model: RuleEditorModel
        let owner: FakeOwnerAPI
        let done: Locked<Int>
    }

    private func makeRig(_ mode: RuleEditorModel.Mode) -> Rig {
        let owner = FakeOwnerAPI()
        let ok: @Sendable (UUID, IdempotencyKey) async throws -> PlainOutcome = { _, key in
            .completed(.object([:]), key: key.value, command: .saveRule)
        }
        owner.script {
            $0.addRule = { _, key in .completed(.object([:]), key: key.value, command: .addRule) }
            $0.saveRule = { _, _, key in .completed(.object([:]), key: key.value, command: .saveRule) }
            $0.revertRule = ok
            $0.removeRule = ok
        }
        let done = Locked(0)
        let model = RuleEditorModel(mode: mode, api: owner, onDone: { done.update { $0 += 1 } })
        return Rig(model: model, owner: owner, done: done)
    }

    private func shipped(_ key: String) throws -> RuleRow {
        try #require(try Fixtures.shippedRows().first { $0.rule.key == key })
    }

    private func body(_ request: SaveRuleRequest) -> JSONValue? { FakeCall.json(request) }

    // MARK: adding (RD-21, RD-22)

    @Test("Add offers five moments and four scopes in their words")
    func addOffers() {
        #expect(RuleEditorModel.offeredHooks == [
            .taskBeforeReady, .taskBeforeClaim, .taskBeforeSubmit, .taskBeforeDone, .actionRequested,
        ])
        #expect(RuleEditorModel.offeredHooks.map(\.momentName) == [
            "when a task is ready to start", "before an agent starts it", "before work is submitted",
            "when the review has passed", "before anything goes out",
        ])
        #expect(RuleEditorModel.offeredScopes == [.allTasks, .checkerDecides, .namedProjects, .actionKinds])
        #expect(RulesCopy.scopeWords(.namedProjects).text == "Tasks in these projects")
        #expect(RulesCopy.scopeWords(.actionKinds).text == "Tasks that end in")
    }

    @Test("Add shows the name, the instruction, the moment and the scope, and neither Revert nor Remove")
    func addShows() {
        let model = makeRig(.add).model
        #expect(model.canEditName)
        #expect(model.showsInstruction)
        #expect(model.showsHook)
        #expect(model.showsScope)
        #expect(!model.showsOnFail)
        #expect(!model.canRevert)
        #expect(!model.canRemove)
        #expect(model.hook == .taskBeforeReady)
        #expect(model.scopeKind == .allTasks)
    }

    @Test("Add can be saved once it has a name and an instruction, and not before")
    func addNeedsBoth() {
        let model = makeRig(.add).model
        #expect(!model.canSave)
        model.name = "Mention the date"
        #expect(!model.canSave)
        model.instruction = "   "
        #expect(!model.canSave)
        model.instruction = "The goal names a date."
        #expect(model.canSave)
        model.name = "  "
        #expect(!model.canSave)
    }

    @Test("Add sends the name, the instruction, the chosen moment and scope, and closes the sheet")
    func addSends() async {
        let rig = makeRig(.add)
        rig.model.name = "  Mention the date "
        rig.model.instruction = " The goal names a date. "
        rig.model.hook = .taskBeforeDone
        rig.model.scopeKind = .checkerDecides
        await rig.model.save()
        let request = AddRuleRequest(
            name: "Mention the date", instruction: "The goal names a date.", hook: .taskBeforeDone,
            scope: .checkerDecides)
        #expect(rig.owner.calls.map(\.operation) == [.addRule])
        #expect(rig.owner.calls.first?.body == FakeCall.json(request))
        #expect(rig.owner.calls.first?.key != nil)
        #expect(rig.model.state == .done)
        #expect(rig.done.value == 1)
    }

    // Review finding 16: the refusal was answered, so sending again is a new
    // command with a new key (it used to reuse the key and replay the refusal).
    @Test("a name already used keeps the sheet open with a sentence, and sending again uses a new key")
    func addRefusedKeepsKey() async throws {
        let rig = makeRig(.add)
        rig.owner.script {
            $0.addRule = { _, key in
                .refused(Refusal(code: .duplicateName, ruleID: nil, reason: nil), key: key.value, command: .addRule)
            }
        }
        rig.model.name = "Mention the date"
        rig.model.instruction = "The goal names a date."
        await rig.model.save()
        #expect(rig.model.state == .failed(.refusalDuplicateName))
        #expect(rig.model.failure == .refusalDuplicateName)
        #expect(rig.done.value == 0)
        await rig.model.save()
        let keys = rig.owner.calls.compactMap(\.key)
        try #require(keys.count == 2)
        #expect(keys[0] != keys[1])
        rig.model.name = "Mention a date"
        await rig.model.save()
        #expect(rig.owner.calls.compactMap(\.key).last != keys[0])
    }

    // MARK: changing a shipped rule that an agent checks

    @Test("a shipped model rule shows its instruction, its scope and its stop-or-note choice, with Revert and no Remove")
    func shippedModelShows() throws {
        let model = makeRig(.change(try shipped("specific_details"))).model
        #expect(!model.canEditName)
        #expect(model.showsInstruction)
        #expect(model.showsScope)
        #expect(model.showsOnFail)
        #expect(!model.showsHook)
        #expect(model.canRevert)
        #expect(!model.canRemove)
        #expect(model.parameters.isEmpty)
        #expect(model.instruction == (try shipped("specific_details")).version.instruction)
        #expect(model.onFail == .block)
    }

    @Test("a change that is not made cannot be saved, and an empty instruction cannot be saved")
    func nothingToSave() throws {
        let model = makeRig(.change(try shipped("specific_details"))).model
        #expect(!model.canSave)
        model.instruction = "A different instruction."
        #expect(model.canSave)
        model.instruction = " "
        #expect(!model.canSave)
    }

    @Test("Save sends every field: the edited instruction, and the name, scope, route and timeouts as they were")
    func saveSendsEveryField() async throws {
        let row = Fixtures.row(
            number: 9, name: "Mention the date", route: .orchestrator, queueTimeout: 45, runTimeout: 240,
            instruction: "The goal names a date.", origin: .custom)
        let rig = makeRig(.change(row))
        rig.model.instruction = "The goal names a date and a place."
        await rig.model.save()
        let expected = SaveRuleRequest(
            name: "Mention the date", instruction: "The goal names a date and a place.", parameters: nil,
            scope: .allTasks, onFail: .block, route: .orchestrator, queueTimeoutSeconds: 45, runTimeoutSeconds: 240)
        #expect(rig.owner.calls.map(\.operation) == [.saveRule])
        #expect(rig.owner.calls.first?.path == ["id": Fixtures.id(9).contractString])
        #expect(rig.owner.calls.first?.body == body(expected))
        #expect(rig.model.state == .done)
        #expect(rig.done.value == 1)
    }

    @Test("the route goes with every save whatever its value: builder, orchestrator, owner, or none")
    func routeWhateverItsValue() async {
        for route in [RuleRoute.builder, .orchestrator, .owner, nil] {
            let row = Fixtures.row(number: 9, name: "Made up", route: route, instruction: "Old", origin: .custom)
            let rig = makeRig(.change(row))
            rig.model.instruction = "New"
            await rig.model.save()
            let expected = SaveRuleRequest(
                name: "Made up", instruction: "New", scope: .allTasks, onFail: .block, route: route)
            #expect(rig.owner.calls.first?.body == body(expected), "\(String(describing: route))")
        }
    }

    @Test("an instruction that was not touched goes back exactly as it was, spaces and all")
    func untouchedInstructionExact() async {
        let row = Fixtures.row(number: 9, name: "Made up", instruction: "  Old, with spaces.\n", origin: .custom)
        let rig = makeRig(.change(row))
        rig.model.onFail = .warn
        await rig.model.save()
        let expected = SaveRuleRequest(
            name: "Made up", instruction: "  Old, with spaces.\n", scope: .allTasks, onFail: .warn, route: .owner)
        #expect(rig.owner.calls.first?.body == body(expected))
    }

    @Test("stop the task or only note it is saved on a gate, and a policy has neither")
    func onFailChoice() async throws {
        let rig = makeRig(.change(try shipped("specific_details")))
        rig.model.onFail = .warn
        #expect(rig.model.canSave)
        await rig.model.save()
        let sent = FakeCall.json(SaveRuleRequest(
            name: "Every task needs specific details", instruction: try shipped("specific_details").version.instruction,
            scope: .allTasks, onFail: .warn, route: .owner))
        #expect(rig.owner.calls.first?.body == sent)

        let policy = makeRig(.change(try shipped("different_provider_review"))).model
        #expect(!policy.showsOnFail)
        #expect(policy.onFail == nil)
    }

    @Test("the scope of a model rule can be every task or the checker decides, and is saved with no ids")
    func scopeChoice() async {
        let row = Fixtures.row(number: 9, name: "Made up", instruction: "Old", origin: .custom)
        let rig = makeRig(.change(row))
        rig.model.scopeKind = .checkerDecides
        #expect(rig.model.canSave)
        await rig.model.save()
        let expected = SaveRuleRequest(
            name: "Made up", instruction: "Old", scope: .checkerDecides, onFail: .block, route: .owner)
        #expect(rig.owner.calls.first?.body == body(expected))
    }

    @Test("A saved project scope is editable and an unchanged selection is kept exactly")
    func existingProjectScope() async {
        let ids = [Fixtures.id(502), Fixtures.id(501)]
        let scope = RuleScope(kind: .namedProjects, projectIDs: ids)
        let row = Fixtures.row(number: 9, name: "Made up", scope: scope, instruction: "Old", origin: .custom)
        let rig = makeRig(.change(row))
        #expect(rig.model.showsScope)
        #expect(rig.model.projectIDs == Set(ids))
        #expect(!rig.model.canSave)
        rig.model.instruction = "New"
        await rig.model.save()
        let expected = SaveRuleRequest(name: "Made up", instruction: "New", scope: scope, onFail: .block, route: .owner)
        #expect(rig.owner.calls.first?.body == body(expected))
    }

    @Test("Add at the outward action moment requires a project selection and sends the selected IDs")
    func addProjectScope() async {
        let rig = makeRig(.add)
        rig.model.name = "Mention the date"
        rig.model.instruction = "The goal names a date."
        rig.model.hook = .actionRequested
        rig.model.scopeKind = .namedProjects
        #expect(!rig.model.canSave)
        await rig.model.save()
        #expect(rig.owner.calls.isEmpty)
        let projectID = Fixtures.id(500)
        rig.model.projectIDs = [projectID]
        #expect(rig.model.canSave)
        await rig.model.save()
        let expected = AddRuleRequest(
            name: "Mention the date", instruction: "The goal names a date.", hook: .actionRequested,
            scope: RuleScope(kind: .namedProjects, projectIDs: [projectID]))
        #expect(rig.owner.calls.last?.body == FakeCall.json(expected))
    }

    @Test("Save changes an action scope and sends the chosen action kinds without leftover project IDs")
    func saveActionScope() async {
        let row = Fixtures.row(
            name: "Made up", scope: RuleScope(kind: .actionKinds, actionKinds: [.publish]), instruction: "Check.")
        let rig = makeRig(.change(row))
        #expect(rig.model.actionKinds == [.publish])
        #expect(!rig.model.canSave)
        rig.model.projectIDs = [Fixtures.id(500)]
        rig.model.actionKinds = []
        #expect(!rig.model.canSave)
        await rig.model.save()
        #expect(rig.owner.calls.isEmpty)
        rig.model.actionKinds = [.delete, .send, .pay]
        #expect(rig.model.canSave)
        await rig.model.save()
        let expected = SaveRuleRequest(
            name: "Made up", instruction: "Check.", scope: RuleScope(kind: .actionKinds, actionKinds: [.pay, .send, .delete]),
            onFail: .block, route: .owner)
        #expect(rig.owner.calls.last?.body == body(expected))
    }

    // MARK: changing a shipped rule that leverage checks itself

    @Test("an app rule shows its numbers and no instruction, scope or name field")
    func appRuleShows() throws {
        let model = makeRig(.change(try shipped("acceptance_criteria"))).model
        #expect(!model.showsInstruction)
        #expect(!model.showsScope)
        #expect(!model.canEditName)
        #expect(model.showsOnFail)
        #expect(model.parameters == [
            RuleEditorModel.ParameterField(key: "minimum_count", label: "Fewest acceptance criteria", text: "1")
        ])
        let threshold = makeRig(.change(try shipped("escalate_after_failed_reviews"))).model
        #expect(threshold.parameters.map(\.label) == ["Failed reviews before a stronger model"])
        #expect(threshold.parameters.map(\.text) == ["2"])
    }

    @Test("a number is saved with the other parameters as they were, and the instruction stays none")
    func appRuleSaves() async throws {
        let row = try shipped("acceptance_criteria")
        let rig = makeRig(.change(row))
        try #require(rig.model.parameters.count == 1)
        rig.model.parameters[0].text = " 3 "
        #expect(rig.model.canSave)
        await rig.model.save()
        let expected = SaveRuleRequest(
            name: "Every task needs acceptance criteria", instruction: nil,
            parameters: ["minimum_count": .number(3)], scope: .allTasks, onFail: .block, route: .owner)
        #expect(rig.owner.calls.first?.body == body(expected))
    }

    @Test("a number that is not a whole number cannot be saved")
    func appRuleBadNumber() throws {
        let model = makeRig(.change(try shipped("acceptance_criteria"))).model
        try #require(model.parameters.count == 1)
        for text in ["", "abc", "-1", "1.5", "2 3"] {
            model.parameters[0].text = text
            #expect(!model.canSave, "\(text)")
        }
        model.parameters[0].text = "0"
        #expect(model.canSave)
    }

    // MARK: a custom rule's name

    @Test("a custom rule can be renamed, and not saved with an empty name")
    func customRename() async {
        let row = Fixtures.row(number: 9, name: "Old name", instruction: "Old", origin: .custom)
        let rig = makeRig(.change(row))
        #expect(rig.model.canEditName)
        #expect(rig.model.name == "Old name")
        rig.model.name = " "
        #expect(!rig.model.canSave)
        rig.model.name = " New name "
        await rig.model.save()
        let expected = SaveRuleRequest(name: "New name", instruction: "Old", scope: .allTasks, onFail: .block, route: .owner)
        #expect(rig.owner.calls.first?.body == body(expected))
    }

    @Test("a shipped rule keeps its name whatever the field holds")
    func shippedNameFixed() async throws {
        let row = try shipped("specific_details")
        let rig = makeRig(.change(row))
        rig.model.name = "Something else"
        rig.model.instruction = "New"
        await rig.model.save()
        let sent = try #require(rig.owner.calls.first?.body)
        guard case .object(let fields) = sent else { Issue.record("not an object"); return }
        #expect(fields["name"] == .string("Every task needs specific details"))
    }

    // MARK: Revert and Remove (RD-5)

    @Test("Revert is only on a shipped rule, sends revert and closes the sheet")
    func revertShippedOnly() async throws {
        let shippedRig = makeRig(.change(try shipped("specific_details")))
        await shippedRig.model.revert()
        #expect(shippedRig.owner.calls.map(\.operation) == [.revertRule])
        #expect(shippedRig.owner.calls.first?.path == ["id": try shipped("specific_details").rule.id.contractString])
        #expect(shippedRig.model.state == .done)
        #expect(shippedRig.done.value == 1)

        let custom = makeRig(.change(Fixtures.row(number: 9, origin: .custom)))
        #expect(!custom.model.canRevert)
        await custom.model.revert()
        #expect(custom.owner.calls.isEmpty)
        #expect(custom.model.state == .editing)
    }

    @Test("Remove is only on a custom rule, sends remove and closes the sheet")
    func removeCustomOnly() async throws {
        let custom = makeRig(.change(Fixtures.row(number: 9, origin: .custom)))
        #expect(custom.model.canRemove)
        await custom.model.remove()
        #expect(custom.owner.calls.map(\.operation) == [.removeRule])
        #expect(custom.owner.calls.first?.path == ["id": Fixtures.id(9).contractString])
        #expect(custom.model.state == .done)
        #expect(custom.done.value == 1)

        let shippedRig = makeRig(.change(try shipped("specific_details")))
        await shippedRig.model.remove()
        #expect(shippedRig.owner.calls.isEmpty)
        #expect(shippedRig.model.state == .editing)
    }

    @Test("a Revert the server refuses keeps the sheet open with a sentence")
    func revertRefused() async throws {
        let rig = makeRig(.change(try shipped("specific_details")))
        rig.owner.script {
            $0.revertRule = { _, key in
                .refused(Refusal(code: .invalidState, ruleID: nil, reason: nil), key: key.value, command: .revertRule)
            }
        }
        await rig.model.revert()
        #expect(rig.model.failure == .refusalInvalidState)
        #expect(rig.done.value == 0)
    }

    // Milestone 4 review, finding 16.
    @Test("after a refusal, Revert, Remove and Save send a new key; after no answer, the same one")
    func newKeyAfterRefusal() async throws {
        let refusal = Refusal(code: .invalidState, ruleID: nil, reason: nil)
        let shippedRig = makeRig(.change(try shipped("specific_details")))
        shippedRig.owner.script {
            $0.revertRule = { _, key in .refused(refusal, key: key.value, command: .revertRule) }
        }
        await shippedRig.model.revert()
        await shippedRig.model.revert()
        let reverts = shippedRig.owner.calls.filter { $0.operation == .revertRule }.map(\.key)
        #expect(reverts.count == 2 && reverts[0] != reverts[1])

        let custom = makeRig(.change(Fixtures.row(number: 9, name: "Made up", instruction: "Old", origin: .custom)))
        let removes = Locked(0)
        custom.owner.script {
            $0.removeRule = { _, key in
                if removes.update({ $0 += 1; return $0 }) == 1 { throw URLError(.timedOut) }
                return .refused(refusal, key: key.value, command: .removeRule)
            }
            $0.saveRule = { _, _, key in .refused(refusal, key: key.value, command: .saveRule) }
        }
        await custom.model.remove()
        await custom.model.remove()
        await custom.model.remove()
        let removed = custom.owner.calls.filter { $0.operation == .removeRule }.map(\.key)
        #expect(removed.count == 3)
        #expect(removed[0] == removed[1], "no answer: the retry is the same command")
        #expect(removed[2] != removed[1], "a refusal was answered: a new command")

        custom.model.instruction = "New"
        await custom.model.save()
        await custom.model.save()
        let saves = custom.owner.calls.filter { $0.operation == .saveRule }.map(\.key)
        #expect(saves.count == 2 && saves[0] != saves[1])
    }

    @Test("a Save that does not get through keeps the sheet open, and a 401 says the sign-in ended")
    func saveFails() async {
        let row = Fixtures.row(number: 9, name: "Made up", instruction: "Old", origin: .custom)
        let rig = makeRig(.change(row))
        rig.owner.script { $0.saveRule = { _, _, _ in throw URLError(.timedOut) } }
        rig.model.instruction = "New"
        await rig.model.save()
        #expect(rig.model.failure == .cannotReach)
        #expect(rig.model.canSave)
        rig.owner.script { $0.saveRule = { _, _, _ in throw ShellFixtures.unauthenticated() } }
        await rig.model.save()
        #expect(rig.model.failure == .transportUnauthenticated)
        #expect(rig.done.value == 0)
    }
}
