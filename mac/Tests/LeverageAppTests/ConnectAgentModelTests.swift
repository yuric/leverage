import Foundation
import LeverageKit
import LeverageTestSupport
import SwiftUI
import Testing

@testable import LeverageApp

private typealias Fixtures = AgentFixtures

@MainActor
@Suite("ConnectAgentModel")
struct ConnectAgentModelTests {
    private let newSeatID = UUID(uuidString: "99999999-9999-4999-8999-999999999999")!

    private func owner(
        logins: [CredentialWithReading]? = nil, prompt: String = Fixtures.landingText
    ) -> FakeOwnerAPI {
        let owner = Fixtures.owner(
            credentials: CredentialsList(credentials: logins ?? Fixtures.credentials().credentials, asOfSeq: 5))
        let id = newSeatID
        owner.script {
            $0.connectSeat = { _, key in
                .completed(SeatConnected(seatID: id), key: key.value, command: .connectSeat)
            }
            $0.issueLandingPrompt = { seatID, connection, key in
                Fixtures.issuedPrompt(seatID, connection: connection, key: key, text: prompt)
            }
        }
        return owner
    }

    private func makeModel(
        _ owner: FakeOwnerAPI, copy: @escaping @MainActor (String) -> Void = { _ in }, connected: Locked<Int> = Locked(0)
    ) -> ConnectAgentModel {
        ConnectAgentModel(api: owner, copy: copy, onConnected: { connected.update { $0 += 1 } })
    }

    private func body(_ owner: FakeOwnerAPI) -> [String: JSONValue] {
        guard case .object(let fields)? = Fixtures.calls(owner, .connectSeat).last?.body else { return [:] }
        return fields
    }

    // MARK: the form

    @Test("a new form runs the agent on a login, as General, with nothing filled in")
    func startsEmpty() async {
        let model = makeModel(owner())
        await model.load()
        #expect(model.mode == .runOnLogin)
        #expect(model.role == .general)
        #expect(model.name.isEmpty && model.modelName.isEmpty && model.effort.isEmpty)
        #expect(model.phase == .editing)
        #expect(!model.canConnect)
    }

    @Test("the logins on offer are the added ones, the first is picked, and the name is required")
    func logins() async {
        let model = makeModel(owner())
        await model.load()
        #expect(model.logins.map(\.label) == ["Claude, Personal", "Codex, Team"])
        #expect(model.credentialID == Fixtures.loginID)
        #expect(!model.canConnect)
        model.name = "  "
        #expect(!model.canConnect)
        model.name = "Builder one"
        #expect(model.canConnect)
    }

    @Test("with no login added, the form says so and offers to add one; it cannot be sent")
    func noLogins() async {
        let owner = owner(logins: [])
        let model = makeModel(owner)
        await model.load()
        #expect(model.logins.isEmpty)
        #expect(model.credentialID == nil)
        model.name = "Builder one"
        #expect(!model.canConnect)
        #expect(model.needsLogin)
        #expect(AgentsCopy.noLogins.text ==
            "A Native agent runs on one of your logins. Add a login first, then connect the agent.")
        #expect(AgentsCopy.addLogin.text == "Add a login")
        await model.connect()
        #expect(Fixtures.calls(owner, .connectSeat).isEmpty)
        model.mode = .connectsOnItsOwn
        #expect(!model.needsLogin)
        #expect(model.canConnect)
        await model.connect()
        #expect(model.phase == .shown)
        #expect(body(owner)["credential_id"] == .null)
    }

    @Test("Connect picks the tool's default after changing the login's provider")
    func resetsModelForAnotherProvider() async {
        let owner = owner()
        let model = makeModel(owner)
        await model.load()
        #expect(model.modelName.isEmpty)
        #expect(AgentsCopy.defaultModel.text == "The tool's default")
        model.modelName = "claude-made-up"
        model.credentialID = Fixtures.secondLoginID
        #expect(model.modelName.isEmpty)
        model.name = "Example agent"
        await model.connect()
        #expect(body(owner)["provider"] == .string("codex"))
        #expect(body(owner)["model"] == .null)
    }

    @Test("Prompt Connect sends no model from the Native form")
    func promptConnectSendsNoModel() async {
        let owner = owner()
        let model = makeModel(owner)
        await model.load()
        model.modelName = "claude-made-up"
        model.mode = .connectsOnItsOwn
        model.name = "Example agent"
        await model.connect()
        #expect(model.phase == .shown)
        #expect(body(owner)["model"] == .null)
    }

    @Test("General offers Gemini and Reviewer hides it")
    func geminiNotForReviewer() async {
        let list = Fixtures.credentials().credentials + [
            Fixtures.credential(Fixtures.geminiLoginID, name: "Antigravity", provider: .gemini, position: 3)
        ]
        let model = makeModel(owner(logins: list))
        await model.load()
        #expect(model.role == .general)
        #expect(model.logins.contains { $0.id == Fixtures.geminiLoginID })
        model.credentialID = Fixtures.geminiLoginID
        model.role = .reviewer
        #expect(model.logins.map(\.id) == [Fixtures.loginID, Fixtures.secondLoginID])
        #expect(model.credentialID == Fixtures.loginID)
        #expect(model.geminiHiddenForReviewer)
        model.role = .builder
        #expect(!model.geminiHiddenForReviewer)
        #expect(model.logins.count == 3)
    }

    @Test("General is offered first alongside the four dedicated roles")
    func roles() {
        #expect(ConnectAgentModel.roles == [.general, .builder, .reviewer, .planner, .orchestrator])
        #expect(ConnectAgentModel.roles.map { AgentsCopy.role($0).text } == ["General", "Builder", "Reviewer", "Planner", "Orchestrator"])
    }

    @Test("Connect and New prompt use the owner's requested words")
    func connectionCopy() {
        #expect(AgentsCopy.modeRunOnLogin.text == "Native: run on my login")
        #expect(AgentsCopy.modeOwn.text == "Prompt: paste into any agent")
        #expect(AgentsCopy.stateConnectsOnItsOwn.text == "Connected by prompt.")
        #expect(AgentsCopy.newPrompt.text == "New prompt")
        #expect(AgentsCopy.landingNote.text.contains("contains the agent’s token"))
    }

    @Test("the shown landing prompt has paste instructions without the replacement confirmation")
    func shownPromptCopy() {
        #expect(AgentsCopy.landingNote.text.hasPrefix("Paste this into the agent."))
        #expect(!AgentsCopy.landingNote.text.contains("gives back its work"))
        #expect(AgentsCopy.newPromptConfirmation.text == "A new prompt stops the agent using the current one and gives back its work.")
    }

    @Test("the General note covers only app-run default models on tested providers")
    func generalCoverage() async {
        let model = ConnectAgentModel(
            api: owner(), copy: { _ in }, onConnected: {},
            testedProviders: [.codex], generalTestedProviders: [.claude])
        await model.load()
        model.role = .general
        #expect(model.chosenProvider == .claude)
        #expect(!model.showsNotTestedNote)
        model.modelName = "custom-model"
        #expect(model.showsNotTestedNote)
        model.modelName = ""
        #expect(!model.showsNotTestedNote)
        model.credentialID = Fixtures.secondLoginID
        #expect(model.showsNotTestedNote)
        model.mode = .connectsOnItsOwn
        model.provider = .claude
        #expect(model.showsNotTestedNote)
        model.provider = .codex
        #expect(model.showsNotTestedNote)
    }

    // MARK: the planner and the orchestrator (RV-5)

    private let note = "Not tested for checking tasks."

    private func orchestratorModel(
        tested: [Provider], logins: [CredentialWithReading]? = nil, owner: FakeOwnerAPI? = nil
    ) async -> ConnectAgentModel {
        let model = ConnectAgentModel(
            api: owner ?? self.owner(logins: logins), copy: { _ in }, onConnected: {}, testedProviders: tested)
        await model.load()
        model.role = .orchestrator
        model.name = "Checker"
        return model
    }

    @Test("the sentence for an orchestrator the eval suite did not cover is the one RM-1 names")
    func noteSentence() {
        #expect(AgentsCopy.notTestedForChecking.text == note)
    }

    @Test("an orchestrator on a login whose provider is not in the tested list gets the note, and may still connect")
    func noteForAnUntestedProvider() async {
        let model = await orchestratorModel(tested: [.codex])
        #expect(model.chosenProvider == .claude)
        #expect(model.showsNotTestedNote)
        #expect(model.canConnect, "nothing is disabled by the note")
    }

    @Test("an orchestrator on a login whose provider is in the tested list gets no note, until it is moved off it")
    func noNoteForATestedProvider() async {
        let model = await orchestratorModel(tested: [.claude])
        #expect(!model.showsNotTestedNote)
        model.credentialID = Fixtures.secondLoginID
        #expect(model.chosenProvider == .codex)
        #expect(model.showsNotTestedNote)
        model.credentialID = Fixtures.loginID
        #expect(!model.showsNotTestedNote)
    }

    @Test("with an empty tested list every orchestrator on a login gets the note")
    func emptyList() async {
        let model = await orchestratorModel(tested: [])
        #expect(model.showsNotTestedNote)
        model.credentialID = Fixtures.secondLoginID
        #expect(model.showsNotTestedNote)
    }

    @Test("a model chosen by the owner brings the note even on a tested provider; spaces alone do not")
    func noteForAChosenModel() async {
        let model = await orchestratorModel(tested: [.claude])
        model.modelName = "   "
        #expect(!model.showsNotTestedNote)
        model.modelName = " some-model "
        #expect(model.showsNotTestedNote)
        model.modelName = ""
        #expect(!model.showsNotTestedNote)
    }

    @Test("an orchestrator that connects on its own gets the note whatever provider it names")
    func noteForConnectingOnItsOwn() async {
        let model = await orchestratorModel(tested: [.claude, .codex, .gemini, .grok])
        model.mode = .connectsOnItsOwn
        model.provider = .claude
        #expect(model.showsNotTestedNote)
        model.mode = .runOnLogin
        #expect(!model.showsNotTestedNote)
    }

    @Test("a builder, a reviewer and a planner never get the checking note")
    func noNoteForOtherRoles() async {
        let model = await orchestratorModel(tested: [])
        model.modelName = "some-model"
        #expect(model.showsNotTestedNote)
        for role in [SeatRole.builder, .reviewer, .planner] {
            model.role = role
            #expect(!model.showsNotTestedNote, "\(role)")
            model.mode = .connectsOnItsOwn
            #expect(!model.showsNotTestedNote, "\(role)")
            model.mode = .runOnLogin
        }
        model.role = .orchestrator
        #expect(model.showsNotTestedNote)
    }

    @Test("with no login to pick the note follows only the model and the way it connects")
    func noteWithNoLogin() async {
        let model = await orchestratorModel(tested: [], logins: [])
        #expect(model.chosenProvider == nil)
        #expect(!model.showsNotTestedNote)
        model.modelName = "some-model"
        #expect(model.showsNotTestedNote)
    }

    @Test("a planner and an orchestrator may pick any login, a Gemini one included, with a model and an effort")
    func jobRolesPickAnyLogin() async {
        let list = Fixtures.credentials().credentials + [
            Fixtures.credential(Fixtures.geminiLoginID, name: "Antigravity", provider: .gemini, position: 3)
        ]
        for role in [SeatRole.planner, .orchestrator] {
            let owner = owner(logins: list)
            let model = await orchestratorModel(tested: [], owner: owner)
            model.role = role
            #expect(model.logins.count == 3, "\(role)")
            #expect(!model.geminiHiddenForReviewer)
            model.credentialID = Fixtures.geminiLoginID
            model.modelName = "some-model"
            model.effort = "high"
            await model.connect()
            let fields = body(owner)
            #expect(fields["role"] == .string(role.rawValue))
            #expect(fields["provider"] == .string("gemini"))
            #expect(fields["credential_id"] == .string(Fixtures.geminiLoginID.contractString))
            #expect(fields["model"] == .string("some-model"))
            #expect(fields["effort"] == .string("high"))
            #expect(model.phase == .done)
        }
    }

    @Test("a reviewer is still offered no Gemini login, and moving to a job role gives it back")
    func reviewerStillHidesGemini() async {
        let list = Fixtures.credentials().credentials + [
            Fixtures.credential(Fixtures.geminiLoginID, name: "Antigravity", provider: .gemini, position: 3)
        ]
        let model = await orchestratorModel(tested: [], logins: list)
        model.role = .reviewer
        #expect(model.logins.count == 2)
        model.role = .orchestrator
        #expect(model.logins.count == 3)
    }

    @Test("an orchestrator that connects on its own is connected like a builder: no login, its provider, and a landing prompt")
    func orchestratorOnItsOwn() async {
        let owner = owner()
        let model = await orchestratorModel(tested: [], owner: owner)
        model.mode = .connectsOnItsOwn
        model.provider = .grok
        await model.connect()
        let fields = body(owner)
        #expect(fields["role"] == .string("orchestrator"))
        #expect(fields["credential_id"] == .null)
        #expect(fields["provider"] == .string("grok"))
        #expect(model.phase == .shown)
        #expect(model.prompt?.state == .ready(Fixtures.landingText))
    }

    @Test("Connect sends the strength chosen for an agent on a login")
    func connectWithStrongerModel() async {
        let owner = owner()
        let model = makeModel(owner)
        await model.load()
        model.name = "Builder on a login"
        model.strengthRank = 2
        await model.connect()
        #expect(body(owner)["strength_rank"] == .number(2))
    }

    @Test("Connect does not send a strength outside the three choices", arguments: [0, 4])
    func connectRejectsUnlistedStrength(_ strength: Int) async {
        let owner = owner()
        let model = makeModel(owner)
        model.mode = .connectsOnItsOwn
        model.name = "Example agent"
        model.strengthRank = strength
        #expect(!model.canConnect)
        await model.connect()
        #expect(Fixtures.calls(owner, .connectSeat).isEmpty)
    }

    @Test("prompt connect issues the chosen connection and copies the full text",
          arguments: LandingPromptConnection.allCases)
    func connectUsing(_ connection: LandingPromptConnection) async {
        let owner = owner()
        let board = Fixtures.pasteboard()
        let model = makeModel(owner, copy: board.copy)
        model.mode = .connectsOnItsOwn
        model.connection = connection
        model.role = .reviewer
        model.name = "Independent reviewer"
        model.strengthRank = 3
        await model.connect()
        let calls = owner.calls.filter { [.connectSeat, .issueLandingPrompt].contains($0.operation) }
        #expect(calls.map(\.operation) == [.connectSeat, .issueLandingPrompt])
        #expect(calls.last?.path["id"] == newSeatID.contractString)
        #expect(calls.last?.body == .object(["connection": .string(connection.rawValue)]))
        #expect(body(owner)["strength_rank"] == .number(3))
        #expect(model.prompt?.state == .ready(Fixtures.landingText))
        #expect(board.copied.value.isEmpty)
        model.prompt?.copyPrompt()
        #expect(board.copied.value == [Fixtures.landingText])
        model.finish()
        #expect(model.prompt == nil)
    }

    @Test("a landing prompt for the wrong connection or seat is rejected", arguments: [true, false])
    func rejectsWrongPrompt(wrongSeat: Bool) async {
        let owner = owner()
        owner.script {
            $0.issueLandingPrompt = { seatID, connection, key in
                Fixtures.issuedPrompt(
                    wrongSeat ? Fixtures.ownID : seatID,
                    connection: wrongSeat ? connection : .http, key: key)
            }
        }
        let model = makeModel(owner)
        model.mode = .connectsOnItsOwn
        model.connection = .mcp
        model.name = "Independent builder"
        await model.connect()
        #expect(model.prompt?.state == .failed(ShellCopy.somethingWentWrong.text))
    }

    // MARK: a seat the app runs

    @Test("connecting on a login sends role, name, the login and its provider; model and effort are null when empty")
    func connectOnLogin() async {
        let owner = owner()
        let connected = Locked(0)
        let model = makeModel(owner, connected: connected)
        await model.load()
        model.role = .builder
        model.name = " Builder one "
        model.credentialID = Fixtures.secondLoginID
        await model.connect()
        let fields = body(owner)
        #expect(fields["name"] == .string("Builder one"))
        #expect(fields["role"] == .string("builder"))
        #expect(fields["provider"] == .string("codex"))
        #expect(fields["credential_id"] == .string(Fixtures.secondLoginID.contractString))
        #expect(fields["model"] == .null)
        #expect(fields["effort"] == .null)
        #expect(fields["strength_rank"] == .number(1))
        #expect(model.phase == .done)
        #expect(model.prompt == nil)
        #expect(connected.value == 1)
    }

    @Test("model and effort the owner typed are sent as typed")
    func modelAndEffort() async {
        let owner = owner()
        let model = makeModel(owner)
        await model.load()
        model.name = "Reviewer one"
        model.role = .reviewer
        model.modelName = "some-model"
        model.effort = "high"
        await model.connect()
        let fields = body(owner)
        #expect(fields["role"] == .string("reviewer"))
        #expect(fields["model"] == .string("some-model"))
        #expect(fields["effort"] == .string("high"))
    }

    @Test("Effort is offered only for a tool that takes one, and is never sent for one that does not")
    func effortOnlyWhereTaken() async {
        let owner = owner()
        let model = makeModel(owner)
        await model.load()
        model.name = "Builder one"
        #expect(model.offersEffort, "the first login is Claude's")
        model.credentialID = Fixtures.secondLoginID
        #expect(!model.offersEffort, "Codex is given no effort")
        model.effort = "high"
        await model.connect()
        #expect(body(owner)["effort"] == .null)

        let own = makeModel(FakeOwnerAPI())
        own.mode = .connectsOnItsOwn
        own.provider = .grok
        #expect(!own.offersEffort)
        own.provider = .gemini
        #expect(own.offersEffort)
    }

    @Test("a seat the app runs asks for no landing prompt")
    func noPromptForLogin() async {
        let owner = owner()
        let model = makeModel(owner)
        await model.load()
        model.name = "Builder one"
        await model.connect()
        #expect(Fixtures.calls(owner, .issueLandingPrompt).isEmpty)
        #expect(model.prompt == nil)
    }

    // MARK: a seat that connects on its own

    private func connectOnItsOwn(_ owner: FakeOwnerAPI, copy: @escaping @MainActor (String) -> Void = { _ in }) async -> ConnectAgentModel {
        let model = makeModel(owner, copy: copy)
        await model.load()
        model.mode = .connectsOnItsOwn
        model.name = "Helper agent"
        model.provider = .grok
        await model.connect()
        return model
    }

    @Test("connecting by prompt sends the chosen provider, role and no credential")
    func connectOwn() async {
        let owner = owner()
        let model = await connectOnItsOwn(owner)
        let fields = body(owner)
        #expect(fields["credential_id"] == .null)
        #expect(fields["provider"] == .string("grok"))
        #expect(fields["role"] == .string("general"))
        #expect(model.phase == .shown)
        #expect(model.prompt?.state == .ready(Fixtures.landingText))
    }

    @Test("a missing key or a second token-shaped string makes a prompt uncopyable",
          arguments: [false, true])
    func refusesUnusableText(containsSecondToken: Bool) async {
        let board = Fixtures.pasteboard()
        let text = containsSecondToken ? Fixtures.landingText + " " + Fixtures.madeUpToken + "-other" : "Read your rules first."
        let model = await connectOnItsOwn(owner(prompt: text), copy: board.copy)
        #expect(model.prompt?.state == .failed(ShellCopy.somethingWentWrong.text))
        model.prompt?.copyPrompt()
        #expect(board.copied.value.isEmpty)
    }

    @Test("retry after a lost response keeps the key, then an answered repeat issues again with a fresh key")
    func repeatedAnswer() async {
        let owner = owner()
        let attempts = Locked(0)
        owner.script {
            $0.issueLandingPrompt = { seatID, connection, key in
                switch attempts.update({ $0 += 1; return $0 }) {
                case 1: throw URLError(.timedOut)
                case 2:
                    return .completed(.repeated(LandingPromptIssuedRepeated(seatID: seatID, connection: connection)),
                                      key: key.value, command: .issueLandingPrompt)
                default: return Fixtures.issuedPrompt(seatID, connection: connection, key: key)
                }
            }
        }
        let model = await connectOnItsOwn(owner)
        #expect(model.prompt?.state == .failed(ShellCopy.cannotReach.text))
        await model.prompt?.issue()
        let keys = Fixtures.calls(owner, .issueLandingPrompt).compactMap(\.key)
        #expect(keys.count == 3)
        #expect(Set(keys).count == 2)
        #expect(keys.prefix(2).first == keys.prefix(2).last)
        #expect(Fixtures.calls(owner, .connectSeat).count == 1)
        #expect(model.prompt?.state == .ready(Fixtures.landingText))
    }

    @Test("closing a shown prompt clears its text and prevents copying from an old reference")
    func finishForgets() async throws {
        let board = Fixtures.pasteboard()
        let model = await connectOnItsOwn(owner(), copy: board.copy)
        let prompt = try #require(model.prompt)
        #expect(prompt.state == .ready(Fixtures.landingText))
        model.finish()
        #expect(model.prompt == nil)
        #expect(prompt.state == .none)
        prompt.copyPrompt()
        #expect(board.copied.value.isEmpty)
    }

    @Test("prompt state diagnostics never print its text or token")
    func neverPrintsToken() async {
        let model = await connectOnItsOwn(owner())
        #expect(model.prompt?.state == .ready(Fixtures.landingText))
        let description = String(reflecting: model.prompt?.state)
        #expect(!description.contains(Fixtures.madeUpToken))
        #expect(!description.contains(Fixtures.landingText))
    }

    // MARK: keys, refusals, failures

    @Test("pressing Connect again after the network failed sends the same command under the same key")
    func sameKeyOnRetry() async {
        let owner = owner()
        let attempts = Locked(0)
        let id = newSeatID
        owner.script {
            $0.connectSeat = { _, key in
                if attempts.update({ $0 += 1; return $0 }) == 1 { throw URLError(.networkConnectionLost) }
                return .completed(SeatConnected(seatID: id), key: key.value, command: .connectSeat)
            }
        }
        let model = makeModel(owner)
        await model.load()
        model.name = "Builder one"
        await model.connect()
        #expect(model.failure == ShellCopy.cannotReach.text)
        #expect(model.phase == .editing)
        await model.connect()
        let keys = Fixtures.calls(owner, .connectSeat).map(\.key)
        #expect(keys.count == 2 && keys[0] == keys[1])
        #expect(model.phase == .done)
    }

    @Test("changing the form drops the key, because the server refuses one key with two bodies")
    func newKeyWhenChanged() async {
        let owner = owner()
        owner.script { $0.connectSeat = { _, _ in throw URLError(.timedOut) } }
        let model = makeModel(owner)
        await model.load()
        model.name = "Builder one"
        await model.connect()
        model.name = "Builder two"
        await model.connect()
        let keys = Fixtures.calls(owner, .connectSeat).map(\.key)
        #expect(keys.count == 2 && keys[0] != keys[1])
    }

    @Test("a name already used is refused under the name field with a plain line")
    func duplicateName() async {
        let owner = owner()
        let refusal = Refusal(code: .duplicateName, ruleID: nil, reason: nil)
        owner.script { $0.connectSeat = { _, key in .refused(refusal, key: key.value, command: .connectSeat) } }
        let model = makeModel(owner)
        await model.load()
        model.name = "Builder one"
        await model.connect()
        #expect(model.nameLine == ShellCopy.refusalDuplicateName.text)
        #expect(model.failure == nil)
        #expect(model.phase == .editing)
        model.name = "Builder two"
        #expect(model.nameLine == nil)
    }

    @Test("any other refusal shows the sentence for its code")
    func otherRefusal() async {
        let owner = owner()
        let refusal = Refusal(code: .forbidden, ruleID: nil, reason: "never shown")
        owner.script { $0.connectSeat = { _, key in .refused(refusal, key: key.value, command: .connectSeat) } }
        let model = makeModel(owner)
        await model.load()
        model.name = "Builder one"
        await model.connect()
        #expect(model.failure == ShellCopy.refusalForbidden.text)
    }

    @Test("a form with no name sends nothing, and a second press while one is in flight sends nothing")
    func guards() async {
        let owner = owner()
        let model = makeModel(owner)
        await model.load()
        await model.connect()
        #expect(Fixtures.calls(owner, .connectSeat).isEmpty)
    }

    @Test("a 401 leaves the form with the signed-out sentence")
    func signedOut() async {
        let owner = owner()
        owner.script { $0.connectSeat = { _, _ in throw ShellFixtures.unauthenticated() } }
        let model = makeModel(owner)
        await model.load()
        model.name = "Builder one"
        await model.connect()
        #expect(model.failure == ShellCopy.transportUnauthenticated.text)
    }

    @Test("the credentials that cannot be read leave the form open with the sentence")
    func credentialsFail() async {
        let owner = owner()
        owner.script { $0.credentials = { throw URLError(.cannotConnectToHost) } }
        let model = makeModel(owner)
        await model.load()
        #expect(model.failure == ShellCopy.cannotReach.text)
        #expect(model.logins.isEmpty)
    }

    // MARK: the screen

    @Test("the Connect sheet draws in each of its states, light and dark")
    func renders() async {
        let editing = makeModel(owner())
        await editing.load()
        #expect(Fixtures.draws(ConnectAgentForm(model: editing, cancel: {}, addLogin: {}), width: 480, height: 640))
        editing.mode = .connectsOnItsOwn
        #expect(Fixtures.draws(ConnectAgentForm(model: editing, cancel: {}, addLogin: {}).environment(\.colorScheme, .dark), width: 480, height: 640))
        let shown = await connectOnItsOwn(owner())
        #expect(Fixtures.draws(ConnectAgentForm(model: shown, cancel: {}, addLogin: {}), width: 480, height: 640))
        let none = makeModel(owner(logins: []))
        await none.load()
        #expect(Fixtures.draws(ConnectAgentForm(model: none, cancel: {}, addLogin: {}), width: 480, height: 640))
        let checker = await orchestratorModel(tested: [])
        #expect(checker.showsNotTestedNote)
        #expect(Fixtures.draws(ConnectAgentForm(model: checker, cancel: {}, addLogin: {}), width: 480, height: 640))
    }
}
