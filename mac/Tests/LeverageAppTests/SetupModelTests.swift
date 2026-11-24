import Foundation
import LeverageKit
import LeverageTestSupport
import Testing

@testable import LeverageApp

private typealias Fixtures = AgentFixtures

/// Made-up workspaces for the setup tests.
enum SetupFixtures {
    static func task(_ title: String, _ state: TaskState) -> BoardTask {
        BoardTask(task: TaskSummary(
            id: UUID(), title: title, goal: "g", details: nil, state: state, round: 0, workReference: nil,
            priority: .normal))
    }

    static func board(_ tasks: [BoardTask] = [], asOfSeq: Int = 9) -> Board {
        Board(tasks: tasks, asOfSeq: asOfSeq, reviewerSeatExists: true)
    }

    /// A workspace with nothing in it.
    static func emptyOwner() -> FakeOwnerAPI {
        Fixtures.owner(
            seats: SeatsList(seats: [], asOfSeq: 3), credentials: CredentialsList(credentials: [], asOfSeq: 3),
            board: board(asOfSeq: 3))
    }

    static let twoLogins = Fixtures.credentials()
    static let oneLogin = CredentialsList(
        credentials: [Fixtures.credential(Fixtures.loginID, name: "Personal", provider: .claude, position: 1)], asOfSeq: 11)
    static let twoAgents = SeatsList(
        seats: [
            Fixtures.seat(Fixtures.builderID, name: "Claude, Personal", role: .general, credential: Fixtures.loginID),
            Fixtures.seat(
                Fixtures.reviewerID, name: "Codex, Team", role: .general, provider: .codex, credential: Fixtures.secondLoginID),
        ], asOfSeq: 12)
}

@MainActor
@Suite("SetupModel")
struct SetupModelTests {
    private typealias Facts = SetupModel.Facts

    private func facts(
        credentials: CredentialsList = CredentialsList(credentials: [], asOfSeq: 1),
        seats: SeatsList = SeatsList(seats: [], asOfSeq: 1), tasks: [BoardTask] = []
    ) -> Facts {
        Facts(credentials: credentials.credentials.map(\.credential), seats: seats.seats, tasks: tasks.map(\.task))
    }

    private func makeModel(
        _ owner: FakeOwnerAPI, choice: SetupChoice = .notChosen, reads: Locked<[Int]> = Locked([])
    ) -> (SetupModel, FakeSetupProgressStore) {
        let store = FakeSetupProgressStore(stored: choice)
        return (SetupModel(api: owner, store: store, noteRead: { seq in reads.update { $0.append(seq) } }), store)
    }

    // MARK: the facts

    @Test("a workspace with nothing in it has no step done and starts at logins")
    func emptyFacts() {
        let empty = facts()
        #expect(empty.isEmpty)
        #expect(empty.doneCount == 0)
        #expect(empty.current == .logins)
        #expect(!empty.allDone)
    }

    @Test("logins are done with two providers, not with two logins of one")
    func loginsNeedTwoProviders() {
        let sameProvider = CredentialsList(
            credentials: [
                Fixtures.credential(Fixtures.loginID, name: "Personal", provider: .claude, position: 1),
                Fixtures.credential(Fixtures.secondLoginID, name: "Work", provider: .claude, position: 2),
            ], asOfSeq: 1)
        #expect(!facts(credentials: sameProvider).isDone(.logins))
        #expect(facts(credentials: sameProvider).loginProviders == [.claude])
        #expect(!facts(credentials: SetupFixtures.oneLogin).isDone(.logins))
        #expect(facts(credentials: SetupFixtures.twoLogins).isDone(.logins))
        #expect(facts(credentials: SetupFixtures.twoLogins).logins.map(\.label) == ["Claude, Personal", "Codex, Team"])
    }

    @Test("an API token is not a login an agent can run on")
    func tokensDoNotCount() {
        let token = CredentialWithReading(credential: Credential(
            id: UUID(), kind: .apiToken, provider: .openrouter, name: "Spare", position: 2))
        let list = CredentialsList(credentials: SetupFixtures.oneLogin.credentials + [token], asOfSeq: 1)
        #expect(facts(credentials: list).logins.count == 1)
        #expect(!facts(credentials: list).isDone(.logins))
        #expect(!facts(credentials: list).isEmpty)
    }

    @Test("agents are done with agents of two providers, and a removed agent does not count")
    func agentsNeedTwoProviders() {
        #expect(facts(seats: SetupFixtures.twoAgents).isDone(.agents))
        var seats = [SetupFixtures.twoAgents.seats[0]]
        seats.append(Fixtures.seat(UUID(), name: "Gone", provider: .codex, removed: Date()))
        let one = facts(seats: SeatsList(seats: seats, asOfSeq: 1))
        #expect(!one.isDone(.agents))
        #expect(one.agents.map(\.name) == ["Claude, Personal"])
    }

    @Test("the next login without an agent is the first in the handoff order that no agent runs on")
    func nextLoginWithoutAgent() {
        let none = facts(credentials: SetupFixtures.twoLogins)
        #expect(none.nextLoginWithoutAgent?.label == "Claude, Personal")
        let one = facts(
            credentials: SetupFixtures.twoLogins, seats: SeatsList(seats: [SetupFixtures.twoAgents.seats[0]], asOfSeq: 1))
        #expect(one.nextLoginWithoutAgent?.label == "Codex, Team")
        #expect(facts(credentials: SetupFixtures.twoLogins, seats: SetupFixtures.twoAgents).nextLoginWithoutAgent == nil)
    }

    @Test("a task counts as sent once it has left Ideas and Backlog, and as done once it is Done")
    func taskSteps() {
        for state in [TaskState.imaginarium, .backlog, .cancelled] {
            let waiting = facts(tasks: [SetupFixtures.task("An idea", state)])
            #expect(!waiting.isDone(.firstTask), "\(state)")
            #expect(!waiting.isEmpty)
        }
        for state in [TaskState.ready, .working, .inReview, .finishing] {
            let sent = facts(tasks: [SetupFixtures.task("Pocket to-do", state)])
            #expect(sent.isDone(.firstTask), "\(state)")
            #expect(!sent.isDone(.done))
        }
        let done = facts(tasks: [SetupFixtures.task("Pocket to-do", .done)])
        #expect(done.isDone(.firstTask))
        #expect(done.doneTask?.title == "Pocket to-do")
    }

    @Test("the current step is the first that is not done, whatever was done after it")
    func currentStep() {
        let taskOnly = facts(tasks: [SetupFixtures.task("Pocket to-do", .ready)])
        #expect(taskOnly.current == .logins)
        #expect(taskOnly.doneCount == 1)
        let all = facts(
            credentials: SetupFixtures.twoLogins, seats: SetupFixtures.twoAgents,
            tasks: [SetupFixtures.task("Pocket to-do", .done)])
        #expect(all.allDone)
        #expect(all.current == nil)
    }

    // MARK: what the first read decides

    @Test("the first read decides by the kept choice and what is true", arguments: [
        // choice, logins, agents, task state, presentation, kept
        (SetupChoice.notChosen, 0, 0, TaskState?.none, SetupModel.Presentation.assistant, SetupChoice?.some(.started)),
        (.notChosen, 1, 0, nil, .checklist, nil),
        (.notChosen, 2, 2, .working, .checklist, nil),
        (.notChosen, 2, 2, .done, .none, .finished),
        (.started, 0, 0, nil, .assistant, nil),
        (.started, 1, 0, nil, .assistant, nil),
        (.started, 2, 2, nil, .assistant, nil),
        (.started, 2, 2, .ready, .none, .finished),
        (.skipped, 0, 0, nil, .checklist, nil),
        (.skipped, 2, 2, .working, .checklist, nil),
        (.skipped, 2, 2, .done, .none, .finished),
        (.finished, 0, 0, nil, .none, nil),
        (.finished, 1, 1, .ready, .none, nil),
    ])
    func entry(
        choice: SetupChoice, logins: Int, agents: Int, task: TaskState?, presentation: SetupModel.Presentation,
        kept: SetupChoice?
    ) {
        let credentials = CredentialsList(credentials: Array(SetupFixtures.twoLogins.credentials.prefix(logins)), asOfSeq: 1)
        let seats = SeatsList(seats: Array(SetupFixtures.twoAgents.seats.prefix(agents)), asOfSeq: 1)
        let answer = SetupModel.entry(
            choice: choice,
            facts: facts(credentials: credentials, seats: seats, tasks: task.map { [SetupFixtures.task("Pocket to-do", $0)] } ?? []))
        #expect(answer.presentation == presentation)
        #expect(answer.keep == kept)
    }

    // MARK: reading

    @Test("nothing is decided before the first read")
    func startsUndecided() {
        let (model, store) = makeModel(SetupFixtures.emptyOwner())
        #expect(model.presentation == .undecided)
        #expect(store.saves.value.isEmpty)
    }

    @Test("a new installation opens the assistant and keeps that it was opened")
    func newInstallation() async {
        let reads = Locked<[Int]>([])
        let (model, store) = makeModel(SetupFixtures.emptyOwner(), reads: reads)
        await model.load()
        #expect(model.presentation == .assistant)
        #expect(store.saves.value == [.started])
        #expect(reads.value == [3])
    }

    @Test("the position noted is the lowest of the three reads")
    func notesLowestPosition() async {
        let reads = Locked<[Int]>([])
        let (model, _) = makeModel(Fixtures.owner(), choice: .skipped, reads: reads)
        await model.load()
        #expect(reads.value == [9])
    }

    @Test("a step turning true never moves the owner out of the assistant")
    func stepsDoNotMoveTheOwner() async {
        let owner = SetupFixtures.emptyOwner()
        let (model, store) = makeModel(owner)
        await model.load()
        owner.script {
            $0.credentials = { SetupFixtures.twoLogins }
            $0.seats = { SetupFixtures.twoAgents }
            $0.board = { SetupFixtures.board([SetupFixtures.task("Pocket to-do", .done)]) }
        }
        await model.load()
        #expect(model.facts.allDone)
        #expect(model.presentation == .assistant)
        #expect(store.saves.value == [.started])
    }

    @Test("when the first read fails the app shows as it is, and a later read brings the checklist, not the assistant")
    func failedFirstRead() async {
        let owner = FakeOwnerAPI()
        let (model, store) = makeModel(owner)
        await model.load()
        #expect(model.presentation == .none)
        #expect(store.saves.value.isEmpty)

        owner.script {
            $0.credentials = { CredentialsList(credentials: [], asOfSeq: 3) }
            $0.seats = { SeatsList(seats: [], asOfSeq: 3) }
            $0.board = { SetupFixtures.board(asOfSeq: 3) }
        }
        await model.load()
        #expect(model.presentation == .checklist)
        #expect(store.saves.value == [.skipped])
    }

    @Test("a read that fails later changes nothing")
    func laterFailureKeepsWhatWasRead() async {
        let owner = Fixtures.owner()
        let (model, _) = makeModel(owner, choice: .skipped)
        await model.load()
        let before = model.facts
        owner.script { $0.seats = { throw URLError(.timedOut) } }
        await model.load()
        #expect(model.presentation == .checklist)
        #expect(model.facts == before)
    }

    @Test("a batch of events reads the workspace again")
    func eventsReadAgain() async {
        let owner = SetupFixtures.emptyOwner()
        let batches = Locked<[EventsPage]>([])
        owner.script {
            $0.events = { _, _, _ in
                while true {
                    if let page = batches.update({ $0.isEmpty ? nil : $0.removeFirst() }) { return page }
                    try await Task.sleep(for: .milliseconds(2))
                }
            }
        }
        let feed = EventFeed(owner: owner, waitSeconds: 25, retryDelay: .milliseconds(5))
        let store = FakeSetupProgressStore(stored: .skipped)
        let model = SetupModel(api: owner, store: store, noteRead: { feed.noteRead(asOfSeq: $0) })
        model.attach(to: feed)
        await model.load()
        #expect(model.facts.logins.isEmpty)

        owner.script { $0.credentials = { SetupFixtures.oneLogin } }
        batches.update { $0.append(EventsPage(events: [ShellFixtures.event(seq: 12)], nextAfterSeq: 12)) }
        #expect(await ShellFixtures.eventually { model.facts.logins.count == 1 })
        model.detach()
        feed.stop()
    }

    // MARK: the owner's choices

    @Test("Set up later closes the assistant, brings the checklist with its spotlight on, and is kept")
    func skip() async {
        let (model, store) = makeModel(SetupFixtures.emptyOwner())
        await model.load()
        model.spotlightOn = false
        model.skipAssistant()
        #expect(model.presentation == .checklist)
        #expect(model.spotlightOn)
        #expect(store.stored.value == .skipped)
    }

    @Test("sending the first task ends setup, names the task once, and is kept")
    func finishAssistant() async {
        let (model, store) = makeModel(SetupFixtures.emptyOwner())
        await model.load()
        model.finishAssistant(sentTask: "Pocket to-do")
        #expect(model.presentation == .none)
        #expect(model.sentTaskTitle == "Pocket to-do")
        #expect(store.stored.value == .finished)
        model.dismissSentTaskLine()
        #expect(model.sentTaskTitle == nil)
    }

    @Test("Finish setup and Hide this end the checklist and are kept")
    func finishChecklist() async {
        let (model, store) = makeModel(Fixtures.owner(), choice: .skipped)
        await model.load()
        model.finishChecklist()
        #expect(model.presentation == .none)
        #expect(store.stored.value == .finished)
    }

    @Test("a choice does nothing from the wrong screen")
    func choicesAreGuarded() async {
        let (model, store) = makeModel(Fixtures.owner(), choice: .skipped)
        await model.load()
        model.skipAssistant()
        model.finishAssistant(sentTask: "x")
        #expect(model.presentation == .checklist)
        #expect(model.sentTaskTitle == nil)
        #expect(store.saves.value.isEmpty)
    }

    @Test("a choice that cannot be kept still holds until the app quits")
    func unkeptChoiceHolds() async {
        let (model, store) = makeModel(SetupFixtures.emptyOwner())
        store.failure.value = URLError(.cannotWriteToFile)
        await model.load()
        #expect(model.presentation == .assistant)
        model.skipAssistant()
        #expect(model.presentation == .checklist)
        #expect(store.stored.value == .notChosen)
    }
}
