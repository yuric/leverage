import Foundation
import LeverageKit
import LeverageTestSupport
import SwiftUI
import Testing

@testable import LeverageApp

private typealias Fixtures = AgentFixtures

/// The Change sheet of an agent (HM-51, HE-27): what it offers, and the body
/// each change sends. Only the fields the owner changed are sent; an emptied
/// model or effort is sent as null, which is the tool's own default.
@MainActor
@Suite("ChangeAgentModel")
struct ChangeAgentModelTests {
    private let claudeLogin = ConnectAgentModel.LoginChoice(
        id: AgentFixtures.loginID, provider: .claude, label: "Claude, Personal")
    private let codexLogin = ConnectAgentModel.LoginChoice(
        id: AgentFixtures.secondLoginID, provider: .codex, label: "Codex, Team")
    private let geminiLogin = ConnectAgentModel.LoginChoice(
        id: AgentFixtures.geminiLoginID, provider: .gemini, label: "Gemini, Work")

    private func appSeat(
        role: SeatRole = .builder, provider: Provider = .claude, credential: UUID = AgentFixtures.loginID,
        model: String? = "claude-made-up", effort: String? = "high", enabled: Bool = true
    ) -> Seat {
        Fixtures.seat(
            Fixtures.builderID, name: "Claude, Personal", role: role, provider: provider, credential: credential,
            run: .stopped, enabled: enabled, model: model, effort: effort)
    }

    private func owner() -> FakeOwnerAPI {
        let owner = FakeOwnerAPI()
        owner.script { $0.changeSeat = { _, _, key in Fixtures.plain(.changeSeat, key: key) } }
        return owner
    }

    private func makeModel(
        _ owner: FakeOwnerAPI, seat: Seat? = nil, logins: [ConnectAgentModel.LoginChoice]? = nil,
        done: Locked<Int> = Locked(0)
    ) -> ChangeAgentModel {
        ChangeAgentModel(
            api: owner, seat: seat ?? appSeat(), logins: logins ?? [claudeLogin, codexLogin, geminiLogin],
            onChanged: { done.update { $0 += 1 } })
    }

    private func body(_ owner: FakeOwnerAPI) -> [String: JSONValue]? {
        guard case .object(let fields)? = Fixtures.calls(owner, .changeSeat).last?.body else { return nil }
        return fields
    }

    @Test("Change shows the stored strength and sends only the new rank when it changes")
    func changeStrength() async {
        let owner = owner()
        let seat = Fixtures.seat(Fixtures.ownID, name: "Builder", strengthRank: 2)
        let model = makeModel(owner, seat: seat)
        #expect(model.strengthRank == 2)
        #expect(model.request == nil)
        model.strengthRank = 3
        await model.save()
        #expect(body(owner) == ["strength_rank": .number(3)])
    }

    @Test("Change does not send a strength outside the three choices", arguments: [0, 4])
    func changeRejectsUnlistedStrength(_ strength: Int) async {
        let owner = owner()
        let model = makeModel(owner)
        model.strengthRank = strength
        #expect(!model.canSave)
        await model.save()
        #expect(Fixtures.calls(owner, .changeSeat).isEmpty)
    }

    @Test("a seat missing a strength reads as Standard without changing the rank on save")
    func missingStrength() async {
        let owner = owner()
        let seat = Fixtures.seat(Fixtures.ownID, name: "Builder", strengthRank: nil)
        let model = makeModel(owner, seat: seat)
        #expect(model.strengthRank == 1)
        model.name = "Renamed builder"
        await model.save()
        #expect(body(owner) == ["name": .string("Renamed builder")])
    }

    // MARK: what the sheet starts with

    @Test("the sheet starts with the agent's own values and nothing to save")
    func startsWithOwnValues() {
        let model = makeModel(owner())
        #expect(model.name == "Claude, Personal")
        #expect(model.modelName == "claude-made-up")
        #expect(model.effort == "high")
        #expect(model.credentialID == Fixtures.loginID)
        #expect(model.enabled)
        #expect(model.phase == .editing)
        #expect(model.request == nil)
        #expect(!model.canSave)
    }

    @Test("an agent with no model or effort of its own starts with both empty")
    func startsEmpty() {
        let model = makeModel(owner(), seat: appSeat(model: nil, effort: nil))
        #expect(model.modelName.isEmpty && model.effort.isEmpty)
        #expect(model.request == nil)
    }

    @Test("the sheet offers the login only for an agent the app runs, and effort only where the tool takes one")
    func offers() {
        #expect(makeModel(owner()).offersLogin)
        #expect(makeModel(owner()).offersEffort)
        let own = Fixtures.seat(Fixtures.ownID, name: "Helper agent", provider: .grok)
        let connects = makeModel(owner(), seat: own)
        #expect(!connects.offersLogin)
        #expect(!connects.offersEffort)
        let codex = makeModel(owner(), seat: appSeat(provider: .codex, credential: Fixtures.secondLoginID))
        #expect(codex.offersLogin && !codex.offersEffort)
    }

    @Test("a reviewer is not offered a Gemini login, and the sheet says why")
    func reviewerHidesGemini() {
        let builder = makeModel(owner())
        #expect(builder.loginChoices.map(\.label) == ["Claude, Personal", "Codex, Team", "Gemini, Work"])
        #expect(!builder.geminiHiddenForReviewer)
        let reviewer = makeModel(owner(), seat: appSeat(role: .reviewer))
        #expect(reviewer.loginChoices.map(\.label) == ["Claude, Personal", "Codex, Team"])
        #expect(reviewer.geminiHiddenForReviewer)
    }

    // MARK: the body of each change

    @Test("General can change to a Gemini login")
    func generalOffersGemini() {
        let model = makeModel(owner(), seat: appSeat(role: .general))
        #expect(model.loginChoices.map(\.id).contains(geminiLogin.id))
        #expect(!model.geminiHiddenForReviewer)
    }

    @Test("a new name is sent alone, trimmed")
    func renamed() async {
        let owner = owner()
        let done = Locked(0)
        let model = makeModel(owner, done: done)
        model.name = "  Claude, Work  "
        #expect(model.canSave)
        await model.save()
        #expect(body(owner) == ["name": .string("Claude, Work")])
        #expect(model.phase == .done)
        #expect(done.value == 1)
    }

    @Test("a new model and effort are sent as text, and an emptied one as null")
    func modelAndEffort() async {
        let owner = owner()
        let model = makeModel(owner)
        model.modelName = " other-model "
        model.effort = ""
        await model.save()
        #expect(body(owner) == ["model": .string("other-model"), "effort": .null])
    }

    @Test("a model set where there was none is sent as text; an effort left as it was is not sent")
    func modelWhereNoneWas() async {
        let owner = owner()
        let model = makeModel(owner, seat: appSeat(model: nil, effort: "high"))
        model.modelName = "chosen"
        await model.save()
        #expect(body(owner) == ["model": .string("chosen")])
    }

    @Test("a new login is sent as its id; the agent's other fields stay out of the body")
    func newLogin() async {
        let owner = owner()
        let model = makeModel(owner)
        model.credentialID = Fixtures.secondLoginID
        model.modelName = "claude-made-up"
        model.effort = "high"
        await model.save()
        let sent = body(owner)
        #expect(sent?["credential_id"] == .string(Fixtures.secondLoginID.contractString))
        #expect(sent?.keys.contains("name") == false)
    }

    @Test("moving to a login of another provider empties the model and effort, which belonged to the old tool")
    func newProviderResetsModel() async {
        let owner = owner()
        let model = makeModel(owner)
        model.credentialID = Fixtures.secondLoginID
        #expect(model.modelName.isEmpty && model.effort.isEmpty)
        #expect(!model.offersEffort)
        await model.save()
        let sent = body(owner)
        #expect(sent?["credential_id"] == .string(Fixtures.secondLoginID.contractString))
        #expect(sent?["model"] == .null)
        // Codex takes no effort, so none is sent.
        #expect(sent?.keys.contains("effort") == false)
    }

    @Test("turning an agent off sends enabled false and says what happens; turning it on says it does not start")
    func offAndOn() async {
        let owner = owner()
        let model = makeModel(owner)
        #expect(model.enabledNote == nil)
        model.enabled = false
        #expect(model.enabledNote?.contains("stops its run") == true)
        #expect(BannedTerms.found(in: model.enabledNote ?? "").isEmpty)
        await model.save()
        #expect(body(owner) == ["enabled": .bool(false)])

        let off = makeModel(owner, seat: appSeat(enabled: false))
        #expect(!off.enabled)
        off.enabled = true
        #expect(off.enabledNote?.contains("does not start it") == true)
    }

    @Test("an agent that connects on its own never sends a login")
    func connectsOnItsOwnSendsNoLogin() async {
        let owner = owner()
        let seat = Fixtures.seat(Fixtures.ownID, name: "Helper agent", provider: .grok)
        let model = makeModel(owner, seat: seat)
        model.credentialID = Fixtures.loginID
        model.name = "Helper"
        await model.save()
        #expect(body(owner) == ["name": .string("Helper")])
    }

    @Test("the role is never sent")
    func noRole() async {
        let owner = owner()
        let model = makeModel(owner)
        model.name = "x"
        model.modelName = "y"
        model.enabled = false
        model.credentialID = Fixtures.secondLoginID
        await model.save()
        #expect(body(owner)?.keys.contains("role") == false)
        #expect(body(owner)?.keys.contains("strength_rank") == false)
    }

    // MARK: what can be saved

    @Test("an empty name cannot be saved, and puts back to the old name leaves nothing to save")
    func nameRules() async {
        let owner = owner()
        let model = makeModel(owner)
        model.name = "   "
        #expect(!model.canSave)
        await model.save()
        #expect(owner.calls.isEmpty)
        model.name = "Claude, Personal"
        #expect(!model.canSave)
        #expect(model.request == nil)
    }

    @Test("a login that is not one of the choices is not sent")
    func unknownLogin() async {
        let owner = owner()
        let model = makeModel(owner)
        model.credentialID = UUID()
        #expect(!model.canSave)
        await model.save()
        #expect(owner.calls.isEmpty)
    }

    // MARK: refusals, keys

    @Test("a name already taken is said under the name; any other refusal is one line on the sheet")
    func refusals() async {
        let owner = owner()
        let duplicate = Refusal(code: .duplicateName, ruleID: nil, reason: nil)
        owner.script { $0.changeSeat = { _, _, key in .refused(duplicate, key: key.value, command: .changeSeat) } }
        let model = makeModel(owner)
        model.name = "Taken"
        await model.save()
        #expect(model.nameLine == ShellCopy.refusalDuplicateName.text)
        #expect(model.failure == nil)
        #expect(model.phase == .editing)

        let invalid = Refusal(code: .invalidState, ruleID: nil, reason: nil)
        owner.script { $0.changeSeat = { _, _, key in .refused(invalid, key: key.value, command: .changeSeat) } }
        model.name = "Another"
        #expect(model.nameLine == nil)
        await model.save()
        #expect(model.failure == ShellCopy.refusalInvalidState.text)
        #expect(model.phase == .editing)
    }

    @Test("the same change sent again after the network failed uses the same key; a changed form, a new one")
    func keys() async {
        let owner = owner()
        let attempts = Locked(0)
        owner.script {
            $0.changeSeat = { _, _, key in
                if attempts.update({ $0 += 1; return $0 }) == 1 { throw URLError(.networkConnectionLost) }
                return Fixtures.plain(.changeSeat, key: key)
            }
        }
        let model = makeModel(owner)
        model.name = "One"
        await model.save()
        #expect(model.failure == ShellCopy.cannotReach.text)
        #expect(model.phase == .editing)
        await model.save()
        let keys = Fixtures.calls(owner, .changeSeat).map(\.key)
        #expect(keys.count == 2 && keys[0] == keys[1])

        // A changed form is a new command, under a new key.
        owner.script { $0.changeSeat = { _, _, key in throw URLError(.networkConnectionLost) } }
        let changed = makeModel(owner)
        changed.name = "Two"
        await changed.save()
        changed.name = "Three"
        await changed.save()
        let all = Fixtures.calls(owner, .changeSeat).map(\.key)
        #expect(all.count == 4 && all[2] != all[3])
    }

    @Test("a refused change does not keep its key")
    func refusedKeyDropped() async {
        let owner = owner()
        let invalid = Refusal(code: .invalidState, ruleID: nil, reason: nil)
        owner.script { $0.changeSeat = { _, _, key in .refused(invalid, key: key.value, command: .changeSeat) } }
        let model = makeModel(owner)
        model.name = "One"
        await model.save()
        await model.save()
        let keys = Fixtures.calls(owner, .changeSeat).map(\.key)
        #expect(keys.count == 2 && keys[0] != keys[1])
    }

    // MARK: words and screen

    @Test("the Change sheet has no role picker")
    func noRolePicker() throws {
        let sheet = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/LeverageApp/Agents/ChangeAgentSheet.swift")
        let code = LiteralScanner.code(of: try String(contentsOf: sheet, encoding: .utf8))
        #expect(!code.contains("AgentsCopy.roleLabel"))
        #expect(!code.contains("SeatRole"))
    }

    @Test("no sentence of the sheet uses a banned word or an email")
    func plainWords() {
        let model = makeModel(owner(), seat: appSeat(role: .reviewer))
        model.enabled = false
        for line in [model.title, model.enabledNote ?? "", AgentsCopy.changeNote.text, AgentsCopy.changeTitle.text] {
            #expect(BannedTerms.found(in: line).isEmpty, "\(line)")
            #expect(!line.contains("@"))
        }
        #expect(model.title == "Change Claude, Personal")
    }

    @Test("the sheet draws for an agent the app runs and for one that connects on its own, light and dark")
    func renders() {
        let runs = makeModel(owner())
        runs.enabled = false
        #expect(Fixtures.draws(ChangeAgentForm(model: runs, cancel: {}), width: 460, height: 560))
        #expect(Fixtures.draws(ChangeAgentForm(model: runs, cancel: {}).environment(\.colorScheme, .dark), width: 460, height: 560))
        let own = makeModel(owner(), seat: Fixtures.seat(Fixtures.ownID, name: "Helper agent", provider: .grok))
        #expect(Fixtures.draws(ChangeAgentForm(model: own, cancel: {}), width: 460, height: 560))
    }
}
