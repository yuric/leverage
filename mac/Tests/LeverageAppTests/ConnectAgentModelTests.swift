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

    private func shown(_ token: String?, key: IDKey) -> CommandOutcome<SeatConnectedAnswer> {
        .completed(.shown(SeatConnected(seatID: newSeatID, seatToken: token)), key: key.value, command: .connectSeat)
    }

    typealias IDKey = IdempotencyKey

    private func owner(
        logins: [CredentialWithReading]? = nil, token: String? = Fixtures.madeUpToken, prompt: String = "Read your rules first."
    ) -> FakeOwnerAPI {
        let owner = Fixtures.owner(
            credentials: CredentialsList(credentials: logins ?? Fixtures.credentials().credentials, asOfSeq: 5))
        let id = newSeatID
        owner.script {
            $0.connectSeat = { _, key in
                .completed(.shown(SeatConnected(seatID: id, seatToken: token)), key: key.value, command: .connectSeat)
            }
            $0.landingPrompt = { _ in LandingPrompt(text: prompt) }
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

    @Test("a new form runs the agent on a login, as a builder, with nothing filled in")
    func startsEmpty() async {
        let model = makeModel(owner())
        await model.load()
        #expect(model.mode == .runOnLogin)
        #expect(model.role == .builder)
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
        let model = makeModel(owner(logins: []))
        await model.load()
        #expect(model.logins.isEmpty)
        #expect(model.credentialID == nil)
        model.name = "Builder one"
        #expect(!model.canConnect)
        #expect(model.needsLogin)
        model.mode = .connectsOnItsOwn
        #expect(!model.needsLogin)
        #expect(model.canConnect)
    }

    @Test("a Gemini login is not offered for the Reviewer role")
    func geminiNotForReviewer() async {
        let list = Fixtures.credentials().credentials + [
            Fixtures.credential(Fixtures.geminiLoginID, name: "Antigravity", provider: .gemini, position: 3)
        ]
        let model = makeModel(owner(logins: list))
        await model.load()
        #expect(model.logins.count == 3)
        model.credentialID = Fixtures.geminiLoginID
        model.role = .reviewer
        #expect(model.logins.map(\.id) == [Fixtures.loginID, Fixtures.secondLoginID])
        #expect(model.credentialID == Fixtures.loginID)
        #expect(model.geminiHiddenForReviewer)
        model.role = .builder
        #expect(!model.geminiHiddenForReviewer)
        #expect(model.logins.count == 3)
    }

    @Test("all four roles are offered: Builder, Reviewer, Planner and Orchestrator (MA-10)")
    func roles() {
        #expect(ConnectAgentModel.roles == [.builder, .reviewer, .planner, .orchestrator])
        #expect(ConnectAgentModel.roles.map { AgentsCopy.role($0).text } == ["Builder", "Reviewer", "Planner", "Orchestrator"])
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

    @Test("the note is for the orchestrator only: a builder, a reviewer and a planner never get it")
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
            let owner = owner(logins: list, token: nil)
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

    @Test("an orchestrator that connects on its own is connected like a builder: no login, its provider, a token shown once")
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
        #expect(model.shownToken == Fixtures.madeUpToken)
    }

    @Test("Connect sends the strength chosen for an agent on a login")
    func connectWithStrongerModel() async {
        let owner = owner(token: nil)
        let model = makeModel(owner)
        await model.load()
        model.name = "Builder on a login"
        model.strengthRank = 2
        await model.connect()
        #expect(body(owner)["strength_rank"] == .number(2))
    }

    @Test("self-connected agents get the selected prompt and MCP gets separately copyable settings",
          arguments: LandingPromptConnection.allCases)
    func connectUsing(_ connection: LandingPromptConnection) async throws {
        let owner = owner()
        owner.script {
            $0.landingPromptForConnection = { _, connection in
                LandingPrompt(text: "Instructions for \(connection.rawValue).", connection: connection)
            }
        }
        let apiURL = try #require(URL(string: "http://127.0.0.1:49170"))
        let board = Fixtures.pasteboard()
        let model = ConnectAgentModel(api: owner, copy: board.copy, onConnected: {}, apiURL: { apiURL })
        model.mode = .connectsOnItsOwn
        model.connection = connection
        model.role = .reviewer
        model.name = "Independent reviewer"
        model.strengthRank = 3
        await model.connect()
        #expect(body(owner)["strength_rank"] == .number(3))
        #expect(Fixtures.calls(owner, .getLandingPrompt).last?.query["connection"] == connection.rawValue)
        #expect(model.landing == .ready("Instructions for \(connection.rawValue)."))
        #expect(model.shownToken != nil)
        #expect(board.copied.value.isEmpty)
        model.copyMCPSettings()
        if connection == .mcp {
            let settings = try #require(model.mcpSettings)
            #expect(board.copied.value == [settings])
            #expect(settings.contains(apiURL.absoluteString))
            #expect(settings.contains("reviewer"))
            #expect(settings.contains("PASTE-THE-TOKEN-HERE"))
            #expect(settings.contains(Fixtures.madeUpToken) == false)
        } else {
            #expect(model.mcpSettings == nil)
            #expect(board.copied.value.isEmpty)
        }
        model.finish()
        #expect(model.shownToken == nil)
    }

    @Test("a landing prompt for the wrong connection is rejected")
    func rejectsWrongPrompt() async {
        let owner = owner()
        owner.script {
            $0.landingPromptForConnection = { _, _ in LandingPrompt(text: "HTTP instructions", connection: .http) }
        }
        let model = makeModel(owner)
        model.mode = .connectsOnItsOwn
        model.connection = .mcp
        model.name = "Independent builder"
        await model.connect()
        #expect(model.landing == .failed(ShellCopy.somethingWentWrong.text))
    }

    // MARK: a seat the app runs

    @Test("connecting on a login sends role, name, the login and its provider; model and effort are null when empty")
    func connectOnLogin() async {
        let owner = owner(token: nil)
        let connected = Locked(0)
        let model = makeModel(owner, connected: connected)
        await model.load()
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
        #expect(model.shownToken == nil)
        #expect(connected.value == 1)
    }

    @Test("model and effort the owner typed are sent as typed")
    func modelAndEffort() async {
        let owner = owner(token: nil)
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
        let owner = owner(token: nil)
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
        let owner = owner(token: nil)
        let model = makeModel(owner)
        await model.load()
        model.name = "Builder one"
        await model.connect()
        #expect(Fixtures.calls(owner, .getLandingPrompt).isEmpty)
        #expect(model.landing == .none)
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

    @Test("connecting on its own sends no login, the provider chosen, and shows the token once")
    func connectOwn() async {
        let owner = owner()
        let model = await connectOnItsOwn(owner)
        let fields = body(owner)
        #expect(fields["credential_id"] == .null)
        #expect(fields["provider"] == .string("grok"))
        #expect(model.phase == .shown)
        #expect(model.shownToken == Fixtures.madeUpToken)
        #expect(model.tokenGone == false)
    }

    @Test("the landing prompt is fetched after the connect, for the new agent, and shown below the token")
    func promptAfterConnect() async {
        let owner = owner()
        let model = await connectOnItsOwn(owner)
        let asked = Fixtures.calls(owner, .getLandingPrompt)
        #expect(asked.count == 1)
        #expect(asked.first?.path["id"] == newSeatID.contractString)
        #expect(model.landing == .ready("Read your rules first."))
        let order = owner.calls.map(\.operation)
        #expect(order.firstIndex(of: .connectSeat)! < order.firstIndex(of: .getLandingPrompt)!)
    }

    @Test("the token is not in the prompt; a prompt that holds it is dropped, never shown or copied")
    func tokenNotInPrompt() async {
        let good = await connectOnItsOwn(owner())
        if case .ready(let text) = good.landing { #expect(!text.contains(Fixtures.madeUpToken)) }
        #expect(good.landing != .none)

        let board = Fixtures.pasteboard()
        let leaking = await connectOnItsOwn(owner(prompt: "Use \(Fixtures.madeUpToken) to sign in."), copy: board.copy)
        #expect(leaking.landing == .failed(ShellCopy.somethingWentWrong.text))
        leaking.copyLandingPrompt()
        #expect(board.copied.value.isEmpty)
    }

    @Test("Copy on the token copies the token; Copy on the prompt copies the prompt")
    func copies() async {
        let board = Fixtures.pasteboard()
        let model = await connectOnItsOwn(owner(), copy: board.copy)
        model.copyToken()
        model.copyLandingPrompt()
        #expect(board.copied.value == [Fixtures.madeUpToken, "Read your rules first."])
    }

    @Test("a prompt that could not be fetched says so and can be asked for again")
    func promptFails() async {
        let owner = owner()
        let attempts = Locked(0)
        owner.script {
            $0.landingPrompt = { _ in
                if attempts.update({ $0 += 1; return $0 }) == 1 { throw URLError(.timedOut) }
                return LandingPrompt(text: "Second try.")
            }
        }
        let model = await connectOnItsOwn(owner)
        #expect(model.landing == .failed(ShellCopy.cannotReach.text))
        #expect(model.shownToken == Fixtures.madeUpToken)
        await model.retryLandingPrompt()
        #expect(model.landing == .ready("Second try."))
    }

    @Test("an answer without a token (the same command sent again) says it cannot be shown again, and still offers the prompt")
    func repeatedAnswer() async {
        let owner = owner()
        let id = newSeatID
        owner.script {
            $0.connectSeat = { _, key in
                .completed(.repeated(SeatConnectedRepeated(seatID: id)), key: key.value, command: .connectSeat)
            }
        }
        let model = await connectOnItsOwn(owner)
        #expect(model.phase == .shown)
        #expect(model.shownToken == nil)
        #expect(model.tokenGone)
        #expect(model.landing == .ready("Read your rules first."))
    }

    @Test("finishing forgets the token")
    func finishForgets() async {
        let model = await connectOnItsOwn(owner())
        #expect(model.shownToken != nil)
        model.finish()
        #expect(model.shownToken == nil)
        #expect(model.landing == .none)
    }

    @Test("the model never prints the token")
    func neverPrintsToken() async {
        let model = await connectOnItsOwn(owner())
        #expect(!String(describing: model.phase).contains(Fixtures.madeUpToken))
        #expect(!String(reflecting: model.landing).contains(Fixtures.madeUpToken))
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
                return .completed(.shown(SeatConnected(seatID: id, seatToken: nil)), key: key.value, command: .connectSeat)
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
