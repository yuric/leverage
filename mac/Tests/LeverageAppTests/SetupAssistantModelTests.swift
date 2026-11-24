import Foundation
import LeverageKit
import LeverageTestSupport
import Testing

@testable import LeverageApp

private typealias Fixtures = AgentFixtures

/// A setup assistant over a fake workspace: the setup state it reads, the
/// window's navigator, and the owner the test scripts.
@MainActor
struct AssistantRig {
    let owner: FakeOwnerAPI
    let setup: SetupModel
    let store: FakeSetupProgressStore
    let navigator: Navigator
    let model: SetupAssistantModel

    /// The workspace answers `credentials`, `seats` and `board` until a test scripts otherwise.
    static func make(
        credentials: CredentialsList = CredentialsList(credentials: [], asOfSeq: 3),
        seats: SeatsList = SeatsList(seats: [], asOfSeq: 3), tasks: [BoardTask] = [],
        choice: SetupChoice = .notChosen
    ) async -> AssistantRig {
        let owner = Fixtures.owner(seats: seats, credentials: credentials, board: SetupFixtures.board(tasks))
        let store = FakeSetupProgressStore(stored: choice)
        let setup = SetupModel(api: owner, store: store)
        await setup.load()
        let navigator = Navigator()
        navigator.show(.agents)
        let runtime = FakeAppRuntime()
        let model = SetupAssistantModel(
            setup: setup, api: owner, helper: runtime.helper, navigator: navigator, timing: .quick)
        return AssistantRig(owner: owner, setup: setup, store: store, navigator: navigator, model: model)
    }

    /// The two-provider workspace: a Claude and a Codex login.
    static func twoLogins(seats: SeatsList = SeatsList(seats: [], asOfSeq: 3)) async -> AssistantRig {
        await make(credentials: SetupFixtures.twoLogins, seats: seats, choice: .started)
    }
}

@MainActor
@Suite("SetupAssistantModel")
struct SetupAssistantModelTests {
    private let helperRequestID = UUID(uuidString: "34343434-3434-4434-8434-343434343434")!

    private func passing() -> HelperRequestStatus {
        Fixtures.request(
            helperRequestID, state: .finished,
            progress: [
                Fixtures.progress(.toolInstalled, .passed), Fixtures.progress(.signedIn, .passed),
                Fixtures.progress(.testPrompt, .passed),
            ], result: Fixtures.finished(), updated: 5)
    }

    private func failing() -> HelperRequestStatus {
        Fixtures.request(
            helperRequestID, state: .failed,
            progress: [Fixtures.progress(.signedIn, .failed, failure: .notSignedIn)],
            result: Fixtures.finished(
                .failed, failing: [HelperCheckResult(check: .signedIn, passed: false, failure: .notSignedIn)]),
            updated: 9)
    }

    /// Add credential answers, the helper answers each of `answers` in turn,
    /// and from the first Add on the Credentials list holds `after`.
    private func scriptLogin(_ owner: FakeOwnerAPI, answers: [HelperRequestStatus], after: CredentialsList) {
        let remaining = Locked(answers)
        let request = helperRequestID
        let added = Locked(false)
        owner.script {
            $0.addCredential = { body, key in
                added.value = true
                return .completed(
                    AddCredentialResult(credentialID: body.credentialID, helperRequestID: request), key: key.value,
                    command: .addCredential)
            }
            $0.helperRequest = { _, _, _ in remaining.update { $0.count > 1 ? $0.removeFirst() : $0[0] } }
            $0.credentials = { added.value ? after : CredentialsList(credentials: [], asOfSeq: 3) }
        }
    }

    private func connectBodies(_ owner: FakeOwnerAPI) -> [[String: JSONValue]] {
        Fixtures.calls(owner, .connectSeat).compactMap {
            if case .object(let fields)? = $0.body { fields } else { nil }
        }
    }

    // MARK: where it opens

    @Test("it opens on Welcome with no login, on the second login with one provider, on Agents with two, and on the first task with their agents")
    func opening() async {
        #expect(await AssistantRig.make().model.screen == .welcome)
        #expect(await AssistantRig.make(credentials: SetupFixtures.oneLogin, choice: .started).model.screen == .secondLogin)
        let sameProvider = CredentialsList(
            credentials: [
                Fixtures.credential(Fixtures.loginID, name: "Personal", provider: .claude, position: 1),
                Fixtures.credential(Fixtures.secondLoginID, name: "Work", provider: .claude, position: 2),
            ], asOfSeq: 3)
        #expect(await AssistantRig.make(credentials: sameProvider, choice: .started).model.screen == .secondLogin)
        #expect(await AssistantRig.twoLogins().model.screen == .agents)
        let oneAgent = SeatsList(seats: [SetupFixtures.twoAgents.seats[0]], asOfSeq: 3)
        #expect(await AssistantRig.twoLogins(seats: oneAgent).model.screen == .agents)
        #expect(await AssistantRig.twoLogins(seats: SetupFixtures.twoAgents).model.screen == .firstTask)
    }

    @Test("the stepper groups the two login screens under Logins, and the screens before the current one are done")
    func stepper() async {
        let rig = await AssistantRig.make()
        #expect(rig.model.stage == .welcome)
        rig.model.next()
        #expect(rig.model.screen == .firstLogin)
        #expect(rig.model.stage == .logins)
        #expect(SetupAssistantModel.Stage.allCases.map(rig.model.isDone) == [true, false, false, false])
        rig.model.back()
        #expect(rig.model.screen == .welcome)
    }

    // MARK: logins

    @Test("the first login screen offers the four logins and no API token, each with the tool it runs in")
    func tiles() async {
        let rig = await AssistantRig.make()
        rig.model.next()
        #expect(rig.model.tiles.map(\.provider) == [.claude, .codex, .gemini, .grok])
        #expect(rig.model.tiles.map(\.tool) == ["Claude Code", "Codex", "Antigravity", "Grok Build"])
        #expect(rig.model.tiles.map(\.note) == [nil, nil, SetupAssistantCopy.geminiTileNote.text, nil])
        #expect(rig.model.tiles.allSatisfy { !$0.isAdded })
        #expect(rig.model.showsTiles)
        #expect(!rig.model.canContinue)
    }

    @Test("signing in adds the login, reads setup again, shows it as added and enables Continue")
    func addsLogin() async {
        let rig = await AssistantRig.make()
        scriptLogin(rig.owner, answers: [passing()], after: SetupFixtures.oneLogin)
        rig.model.next()
        rig.model.pick(.claude)
        let attempt = rig.model.attempt
        #expect(attempt?.provider == .claude)
        attempt?.name = "Personal"
        await rig.model.signIn()
        #expect(rig.model.attempt == nil)
        #expect(rig.setup.facts.logins.map(\.label) == ["Claude, Personal"])
        #expect(!rig.model.showsTiles)
        #expect(rig.model.canContinue)
        guard case .object(let fields)? = Fixtures.calls(rig.owner, .addCredential).first?.body else {
            Issue.record("Add credential was not sent")
            return
        }
        #expect(fields["kind"] == .string("login"))
        #expect(fields["provider"] == .string("claude"))
        #expect(fields["name"] == .string("Personal"))
        rig.model.next()
        #expect(rig.model.screen == .secondLogin)
    }

    @Test("a failed check stays on the screen with its line and Retry, and Retry adds the login")
    func failedCheck() async {
        let rig = await AssistantRig.make()
        scriptLogin(rig.owner, answers: [failing(), passing()], after: SetupFixtures.oneLogin)
        rig.model.next()
        rig.model.pick(.claude)
        rig.model.attempt?.name = "Personal"
        await rig.model.signIn()
        #expect(rig.model.screen == .firstLogin)
        #expect(rig.model.attempt?.failure == CredentialsCopy.failNotSignedIn.filled(["tool": "Claude Code"]))
        #expect(rig.model.attempt?.canRetry == true)
        #expect(!rig.model.canContinue)
        await rig.model.retry()
        #expect(rig.model.attempt == nil)
        #expect(rig.model.canContinue)
        let keys = Fixtures.calls(rig.owner, .addCredential).compactMap(\.key)
        #expect(keys.count == 2 && keys[0] != keys[1])
    }

    @Test("Cancel while the checks run goes back to the tiles, and a new pick starts a new attempt")
    func cancelSignIn() async {
        let rig = await AssistantRig.make()
        scriptLogin(rig.owner, answers: [failing()], after: SetupFixtures.oneLogin)
        rig.model.next()
        rig.model.pick(.codex)
        let first = rig.model.attempt
        rig.model.cancelSignIn()
        #expect(rig.model.attempt == nil)
        #expect(rig.model.showsTiles)
        rig.model.pick(.codex)
        #expect(rig.model.attempt !== first)
    }

    @Test("on the second login a provider already added is disabled and says so, and cannot be picked")
    func secondLoginTiles() async {
        let rig = await AssistantRig.make(credentials: SetupFixtures.oneLogin, choice: .started)
        #expect(rig.model.screen == .secondLogin)
        #expect(rig.model.tiles.map(\.isAdded) == [true, false, false, false])
        rig.model.pick(.claude)
        #expect(rig.model.attempt == nil)
        rig.model.pick(.codex)
        #expect(rig.model.attempt?.provider == .codex)
        #expect(!rig.model.canContinue)
    }

    @Test("a second login from another provider enables Continue to the agents")
    func secondLogin() async {
        let rig = await AssistantRig.make(credentials: SetupFixtures.oneLogin, choice: .started)
        scriptLogin(rig.owner, answers: [passing()], after: SetupFixtures.twoLogins)
        rig.model.pick(.codex)
        rig.model.attempt?.name = "Team"
        await rig.model.signIn()
        #expect(rig.setup.facts.logins.map(\.label) == ["Claude, Personal", "Codex, Team"])
        #expect(rig.model.canContinue)
        rig.model.next()
        #expect(rig.model.screen == .agents)
    }

    @Test("I only have one subscription reveals Continue with one, which goes to the agents")
    func continueWithOne() async {
        let rig = await AssistantRig.make(credentials: SetupFixtures.oneLogin, choice: .started)
        #expect(!rig.model.showsOneSubscription)
        rig.model.toggleOneSubscription()
        #expect(rig.model.showsOneSubscription)
        rig.model.continueWithOne()
        #expect(rig.model.screen == .agents)
        #expect(rig.model.agentRows.map(\.login.label) == ["Claude, Personal"])
        #expect(rig.model.agentNote == .oneProvider)
    }

    // MARK: agents

    @Test("Start agents sends one General agent for each login without one, named after it, on that login")
    func startAgents() async {
        let oneAgent = SeatsList(seats: [SetupFixtures.twoAgents.seats[0]], asOfSeq: 3)
        let rig = await AssistantRig.twoLogins(seats: oneAgent)
        #expect(rig.model.agentRows.map(\.isConnected) == [true, false])
        #expect(!rig.model.agentsStarted)
        rig.owner.script {
            $0.connectSeat = { _, key in .completed(SeatConnected(seatID: UUID()), key: key.value, command: .connectSeat) }
        }
        await rig.model.startAgents()
        let bodies = connectBodies(rig.owner)
        #expect(bodies.count == 1)
        #expect(bodies.first?["name"] == .string("Codex, Team"))
        #expect(bodies.first?["role"] == .string("general"))
        #expect(bodies.first?["provider"] == .string("codex"))
        #expect(bodies.first?["credential_id"] == .string(Fixtures.secondLoginID.contractString))
        #expect(bodies.first?["strength_rank"] == .number(1))
        #expect(bodies.first?["model"] == .null)
        #expect(bodies.first?["effort"] == .null)
        #expect(rig.model.agentRows.map(\.isConnected) == [true, true])
        #expect(rig.model.agentsStarted)
        #expect(rig.model.canContinue)
        #expect(Fixtures.calls(rig.owner, .listSeats).count >= 2)
        rig.model.next()
        #expect(rig.model.screen == .firstTask)
    }

    @Test("a login switched off gets no agent")
    func switchedOff() async {
        let rig = await AssistantRig.twoLogins()
        rig.owner.script {
            $0.connectSeat = { _, key in .completed(SeatConnected(seatID: UUID()), key: key.value, command: .connectSeat) }
        }
        rig.model.setAgent(Fixtures.loginID, on: false)
        #expect(rig.model.agentRows.map(\.isOn) == [false, true])
        await rig.model.startAgents()
        #expect(connectBodies(rig.owner).map { $0["name"] } == [.string("Codex, Team")])
        #expect(rig.model.agentsStarted)
        rig.model.setAgent(Fixtures.secondLoginID, on: false)
        #expect(rig.model.agentRows.map(\.isOn) == [false, true])
    }

    @Test("with every login switched off nothing can be started, and the note says to turn one on")
    func allOff() async {
        let rig = await AssistantRig.twoLogins()
        rig.model.setAgent(Fixtures.loginID, on: false)
        rig.model.setAgent(Fixtures.secondLoginID, on: false)
        #expect(!rig.model.canStartAgents)
        #expect(rig.model.agentNote == .turnOnOne)
        await rig.model.startAgents()
        #expect(Fixtures.calls(rig.owner, .connectSeat).isEmpty)
    }

    @Test("every login already with an agent shows them started, with Continue on")
    func alreadyStarted() async {
        let rig = await AssistantRig.make(
            credentials: SetupFixtures.twoLogins, seats: SetupFixtures.twoAgents, choice: .started)
        rig.model.back()
        #expect(rig.model.screen == .agents)
        #expect(rig.model.agentsStarted)
        #expect(rig.model.canContinue)
        await rig.model.startAgents()
        #expect(Fixtures.calls(rig.owner, .connectSeat).isEmpty)
    }

    @Test("after a network failure the same agent is sent again under the same key, and after an answer under a new one")
    func agentKeys() async {
        let rig = await AssistantRig.twoLogins()
        let attempts = Locked(0)
        let refusal = Refusal(code: .forbidden, ruleID: nil, reason: nil)
        rig.owner.script {
            $0.connectSeat = { body, key in
                guard body.provider == .codex else {
                    return .completed(SeatConnected(seatID: UUID()), key: key.value, command: .connectSeat)
                }
                switch attempts.update({ $0 += 1; return $0 }) {
                case 1: throw URLError(.networkConnectionLost)
                case 2: return .refused(refusal, key: key.value, command: .connectSeat)
                default: return .completed(SeatConnected(seatID: UUID()), key: key.value, command: .connectSeat)
                }
            }
        }
        await rig.model.startAgents()
        #expect(rig.model.agentFailure == ShellCopy.cannotReach.text)
        #expect(rig.model.agentRows.map(\.isConnected) == [true, false])
        await rig.model.startAgents()
        #expect(rig.model.agentFailure == ShellCopy.refusalForbidden.text)
        await rig.model.startAgents()
        #expect(rig.model.agentFailure == nil)
        #expect(rig.model.agentsStarted)

        let calls = Fixtures.calls(rig.owner, .connectSeat)
        #expect(calls.compactMap { $0.body?["provider"]?.stringValue } == ["claude", "codex", "codex", "codex"])
        let codexKeys = calls.dropFirst().compactMap(\.key)
        #expect(codexKeys.count == 3)
        #expect(codexKeys[0] == codexKeys[1])
        #expect(codexKeys[2] != codexKeys[1])
    }

    @Test("a name already used shows the duplicate-name sentence")
    func duplicateName() async {
        let rig = await AssistantRig.twoLogins()
        let refusal = Refusal(code: .duplicateName, ruleID: nil, reason: nil)
        rig.owner.script { $0.connectSeat = { _, key in .refused(refusal, key: key.value, command: .connectSeat) } }
        await rig.model.startAgents()
        #expect(rig.model.agentFailure == ShellCopy.refusalDuplicateName.text)
        #expect(!rig.model.agentsStarted)
        #expect(!rig.model.isStartingAgents)
    }

    @Test("Gemini with one other provider says who reviews what")
    func geminiNote() async {
        let list = CredentialsList(
            credentials: [
                Fixtures.credential(Fixtures.loginID, name: "Personal", provider: .claude, position: 1),
                Fixtures.credential(Fixtures.geminiLoginID, name: "Home", provider: .gemini, position: 2),
            ], asOfSeq: 3)
        let rig = await AssistantRig.make(credentials: list, choice: .started)
        #expect(rig.model.agentNote == .geminiReviews(other: "Claude, Personal"))
        #expect(rig.model.agentRows.map(\.isGemini) == [false, true])
        #expect(await AssistantRig.twoLogins().model.agentNote == nil)
    }

    // MARK: the first task

    @Test("sending a ready-made task adds it, completes its contract with the starter's words, and ends setup on the board")
    func sendsStarter() async throws {
        let rig = await AssistantRig.make(
            credentials: SetupFixtures.twoLogins, seats: SetupFixtures.twoAgents, choice: .started)
        let taskID = UUID()
        rig.owner.script {
            $0.addTask = { _, key in .completed(TaskCreatedResult(taskID: taskID), key: key.value, command: .addTask) }
            $0.completeContract = { _, _, key in Fixtures.plain(.completeContract, key: key) }
        }
        #expect(!rig.model.canSend)
        rig.model.choose(.todo)
        #expect(rig.model.starter == .todo)
        #expect(rig.model.canSend)
        await rig.model.send()

        #expect(rig.owner.calls.filter { [ContractOperation.addTask, .completeContract].contains($0.operation) }.map(\.operation)
            == [.addTask, .completeContract])
        let add = try #require(Fixtures.calls(rig.owner, .addTask).first?.body)
        #expect(add["title"] == .string("Pocket to-do"))
        #expect(add["goal"] == .string(StarterTask.todo.prompt))
        let complete = try #require(Fixtures.calls(rig.owner, .completeContract).first)
        #expect(complete.path["id"] == taskID.contractString)
        #expect(complete.body?["criteria"]?.arrayValue?.compactMap { $0["text"]?.stringValue } == [
            "Tasks are still there after the app restarts", "The N and Space shortcuts work",
            "Tests pass with the command in the README", AddTaskCopy.reviewCriterion.text,
        ])
        #expect(rig.setup.presentation == .none)
        #expect(rig.setup.sentTaskTitle == "Pocket to-do")
        #expect(rig.store.stored.value == .finished)
        #expect(rig.navigator.place == .board)
    }

    @Test("choosing a ready-made task again clears it, and Write my own clears the choice")
    func choosing() async {
        let rig = await AssistantRig.make(
            credentials: SetupFixtures.twoLogins, seats: SetupFixtures.twoAgents, choice: .started)
        rig.model.choose(.tidy)
        rig.model.choose(.tidy)
        #expect(rig.model.starter == nil)
        rig.model.choose(.portfolio)
        rig.model.toggleWriteOwn()
        #expect(rig.model.writesOwn)
        #expect(rig.model.starter == nil)
        rig.model.choose(.portfolio)
        #expect(!rig.model.writesOwn)
    }

    @Test("a task of your own needs both what should get done and how you will know, and goes with its own words")
    func ownTask() async throws {
        let rig = await AssistantRig.make(
            credentials: SetupFixtures.twoLogins, seats: SetupFixtures.twoAgents, choice: .started)
        rig.owner.script {
            $0.addTask = { _, key in .completed(TaskCreatedResult(taskID: UUID()), key: key.value, command: .addTask) }
            $0.completeContract = { _, _, key in Fixtures.plain(.completeContract, key: key) }
        }
        rig.model.toggleWriteOwn()
        rig.model.ownTitle = "Fix the totals"
        #expect(!rig.model.canSend)
        #expect(rig.model.ownNeedsCriteria)
        await rig.model.send()
        #expect(Fixtures.calls(rig.owner, .addTask).isEmpty)
        rig.model.ownTitle = "  "
        rig.model.ownCriteria = "Totals match"
        #expect(!rig.model.canSend)
        rig.model.ownTitle = "Fix the totals"
        #expect(rig.model.canSend)
        await rig.model.send()
        let add = try #require(Fixtures.calls(rig.owner, .addTask).first?.body)
        #expect(add["title"] == .string("Fix the totals"))
        #expect(add["goal"] == .string("Fix the totals"))
        #expect(Fixtures.calls(rig.owner, .completeContract).first?.body?["criteria"]?.arrayValue?.first?["text"]
            == .string("Totals match"))
        #expect(rig.setup.sentTaskTitle == "Fix the totals")
    }

    @Test("a send that fails shows its sentence and stays, and the next press sends only what is missing")
    func sendFails() async {
        let rig = await AssistantRig.make(
            credentials: SetupFixtures.twoLogins, seats: SetupFixtures.twoAgents, choice: .started)
        let attempts = Locked(0)
        rig.owner.script {
            $0.addTask = { _, key in .completed(TaskCreatedResult(taskID: UUID()), key: key.value, command: .addTask) }
            $0.completeContract = { _, _, key in
                if attempts.update({ $0 += 1; return $0 }) == 1 { throw URLError(.timedOut) }
                return Fixtures.plain(.completeContract, key: key)
            }
        }
        rig.model.choose(.portfolio)
        await rig.model.send()
        #expect(rig.model.taskFailure == ShellCopy.cannotReach.text)
        #expect(rig.setup.presentation == .assistant)
        #expect(rig.model.canSend)
        await rig.model.send()
        #expect(rig.model.taskFailure == nil)
        #expect(Fixtures.calls(rig.owner, .addTask).count == 1)
        let keys = Fixtures.calls(rig.owner, .completeContract).compactMap(\.key)
        #expect(keys.count == 2 && keys[0] == keys[1])
        #expect(rig.setup.presentation == .none)
        #expect(rig.setup.sentTaskTitle == "Glass portfolio")
    }

    // MARK: leaving

    @Test("Set up later and Skip, take me to the board both bring the checklist and keep the choice")
    func skips() async {
        let later = await AssistantRig.make()
        later.model.skip()
        #expect(later.setup.presentation == .checklist)
        #expect(later.store.stored.value == .skipped)

        let skip = await AssistantRig.make(
            credentials: SetupFixtures.twoLogins, seats: SetupFixtures.twoAgents, choice: .started)
        #expect(skip.model.screen == .firstTask)
        skip.model.skip()
        #expect(skip.setup.presentation == .checklist)
        #expect(skip.store.stored.value == .skipped)
        #expect(Fixtures.calls(skip.owner, .addTask).isEmpty)
    }

    @Test("leaving a login screen while its checks run stops them")
    func leavingCancels() async {
        let rig = await AssistantRig.make()
        rig.model.next()
        rig.model.pick(.claude)
        #expect(rig.model.attempt != nil)
        rig.model.back()
        #expect(rig.model.attempt == nil)
        #expect(rig.model.screen == .welcome)
    }
}
