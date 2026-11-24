import Foundation
import LeverageKit
import LeverageTestSupport
import Testing

@testable import LeverageApp

private typealias Fixtures = AgentFixtures

/// The setup checklist's card, its side-pane progress, the sent-task line and
/// the two helps inside existing sheets (docs/onboarding/checklist-spotlight.html).
@MainActor
@Suite("SetupChecklist")
struct SetupChecklistTests {
    private typealias Points = SetupPoints
    private typealias Content = SetupChecklistContent

    private func content(_ facts: SetupModel.Facts, cards: [BoardCard] = []) -> Content {
        Content(facts: facts, cards: cards)
    }

    private func card(_ state: TaskState, builder: String = "Claude, Personal") -> BoardCard {
        BoardCard(
            task: Points.task(state), seatNames: [Fixtures.builderID: builder], reviewerSeatExists: true)
    }

    // MARK: the card's head

    @Test("the head says what the card is for and how far setup has come")
    func head() {
        let fresh = content(Points.fresh)
        #expect(fresh.title == "Get your first task done")
        #expect(fresh.subtitle == "Four steps. Each one ticks when it is true, so you can stop and come back.")
        #expect(fresh.doneCount == 0)
        #expect(fresh.progress == "0 of 4")
        #expect(fresh.meterLabel == "0 of 4 done")
        #expect(content(Points.agents).progress == "2 of 4")
        #expect(content(Points.done).progress == "4 of 4")
    }

    // MARK: the steps, for each point of setup

    @Test("a new installation: logins is current with Show me, the rest are later and say what they are")
    func fresh() {
        let steps = content(Points.fresh).steps
        #expect(steps.map(\.title) == [
            "Add two logins", "Connect an agent for each", "Send your first task", "See it reach Done",
        ])
        #expect(steps.map(\.state) == [.current, .later, .later, .later])
        #expect(steps.map(\.foot) == [.showMe, .none, .none, .none])
        #expect(steps.map(\.body) == [
            "From different providers, so one agent can review the other’s work.",
            "An agent does the work and runs on a login.",
            "Use Add task to write what should get done.",
            "One agent builds it, the other reviews it. You are asked only if they need you.",
        ])
    }

    @Test("one login: the step counts one of two")
    func oneLogin() {
        let steps = content(Points.oneLogin).steps
        #expect(steps[0].state == .current)
        #expect(steps[0].body == "From different providers, so one agent can review the other’s work. 1 of 2 added.")
        // Two logins of one provider still count as one.
        #expect(content(Points.twoLoginsOneProvider).steps[0].body.hasSuffix("1 of 2 added."))
    }

    @Test("two logins: logins is done and names them, agents is current")
    func twoLogins() {
        let steps = content(Points.twoLogins).steps
        #expect(steps.map(\.state) == [.done, .current, .later, .later])
        #expect(steps.map(\.foot) == [.done, .showMe, .none, .none])
        #expect(steps[0].body == "Claude, Personal and Codex, Team.")
        #expect(steps[1].body == "An agent does the work and runs on a login.")
    }

    @Test("one agent: the step counts one of two")
    func oneAgent() {
        #expect(content(Points.oneAgent).steps[1].body == "An agent does the work and runs on a login. 1 of 2 connected.")
    }

    @Test("agents connected: the step names them, and sending a task is current")
    func agents() {
        let steps = content(Points.agents).steps
        #expect(steps.map(\.state) == [.done, .done, .current, .later])
        #expect(steps[1].body == "Claude, Personal and Codex, Team are connected.")
        #expect(steps[2].foot == .showMe)
    }

    @Test("the first task running: the step names it, and the last step shows the card's own line, not a button")
    func running() {
        let steps = content(Points.running, cards: [card(.working)]).steps
        #expect(steps.map(\.state) == [.done, .done, .done, .current])
        #expect(steps[2].body == "Pocket to-do.")
        #expect(steps[3].foot == .live("Claude, Personal is building"))
        #expect(!steps.contains { $0.foot == .showMe })
    }

    @Test("the live line follows the task's card as it moves, and says one plain sentence when the card is not known")
    func liveLine() {
        let ready = Points.facts(
            [Points.claude, Points.codex], [Points.claudeAgent, Points.codexAgent], [Points.task(.ready)])
        #expect(content(ready, cards: [card(.ready)]).steps[3].foot == .live("Waiting for a free agent"))
        let review = Points.facts(
            [Points.claude, Points.codex], [Points.claudeAgent, Points.codexAgent], [Points.task(.inReview)])
        #expect(content(review, cards: [card(.inReview)]).steps[3].foot == .live("Claude, Personal's work is being reviewed"))
        #expect(content(Points.running, cards: []).steps[3].foot == .live("Sent to your agents"))
    }

    @Test("all four done: the card is the finished strip")
    func finished() {
        let done = content(Points.done)
        #expect(done.isFinished)
        #expect(done.steps.map(\.state) == [.done, .done, .done, .done])
        #expect(done.steps[3].body == "It reached Done.")
        #expect(done.finishedTitle == "Setup is finished.")
        #expect(done.finishedBody == "For the next one, use Add task.")
        #expect(!content(Points.running).isFinished)
    }

    @Test("a step done out of order is done, and the current step is still the first that is not")
    func outOfOrder() {
        let taskFirst = Points.facts([], [], [Points.task(.ready)])
        let steps = content(taskFirst).steps
        #expect(steps.map(\.state) == [.current, .later, .done, .later])
        #expect(steps[2].foot == .done)
        #expect(content(taskFirst).progress == "1 of 4")
    }

    // MARK: the owner's buttons

    @Test("Show me turns the spotlight on, and Hide this ends the checklist and is kept")
    func showMeAndHide() async {
        let store = FakeSetupProgressStore(stored: .skipped)
        let owner = Fixtures.owner(
            seats: SeatsList(seats: [], asOfSeq: 1),
            credentials: CredentialsList(credentials: [Points.claude], asOfSeq: 1))
        let setup = SetupModel(api: owner, store: store)
        await setup.load()
        setup.notNow()
        #expect(!setup.spotlightOn)
        setup.showMe()
        #expect(setup.spotlightOn)
        setup.hideChecklist()
        #expect(setup.presentation == .none)
        #expect(store.stored.value == .finished)
    }

    @Test("Finish setup on the finished strip ends the checklist and is kept")
    func finishSetup() async {
        let store = FakeSetupProgressStore(stored: .skipped)
        let owner = Fixtures.owner(
            seats: SeatsList(seats: [Points.claudeAgent], asOfSeq: 1),
            credentials: CredentialsList(credentials: [Points.claude], asOfSeq: 1))
        let setup = SetupModel(api: owner, store: store)
        await setup.load()
        setup.finishChecklist()
        #expect(setup.presentation == .none)
        #expect(store.saves.value == [.finished])
    }

    // MARK: what the task board and the side pane show

    @Test("the task board and the side pane show setup only on the checklist")
    func showsOnlyOnChecklist() async {
        let checklist = await Points.checklist([Points.claude])
        #expect(SetupBoardHeader.showsChecklist(checklist))
        #expect(SetupProgressPill.shows(checklist))

        let finished = await Points.checklist([Points.claude], choice: .finished)
        #expect(!SetupBoardHeader.showsChecklist(finished))
        #expect(!SetupProgressPill.shows(finished))
        #expect(finished.sentTaskTitle == nil)

        let undecided = SetupModel(api: FakeOwnerAPI(), store: FakeSetupProgressStore())
        #expect(!SetupBoardHeader.showsChecklist(undecided))
        #expect(!SetupProgressPill.shows(undecided))
    }

    @Test("the side pane's progress says Setup and how many steps are done")
    func sidePane() {
        #expect(SetupChecklistCopy.sidePaneTitle.text == "Setup")
        #expect(content(Points.oneAgent).progress == "1 of 4")
        #expect(content(Points.agents).progress == "2 of 4")
        let navigator = Navigator()
        navigator.show(.agents)
        SetupProgressPill.open(navigator)
        #expect(navigator.place == .board)
        #expect(navigator.openTaskID == nil)
    }

    @Test("after the assistant sends a task, one line names it until it is closed")
    func sentTaskLine() async {
        let owner = SetupFixtures.emptyOwner()
        let setup = SetupModel(api: owner, store: FakeSetupProgressStore())
        await setup.load()
        setup.finishAssistant(sentTask: "Pocket to-do")
        #expect(setup.presentation == .none)
        #expect(!SetupBoardHeader.showsChecklist(setup))
        #expect(SetupBoardHeader.sentTaskLine(setup)
            == "You are set up. Your agents will pick up Pocket to-do. Anything that needs you shows up in Needs you.")
        setup.dismissSentTaskLine()
        #expect(SetupBoardHeader.sentTaskLine(setup) == nil)
    }

    // MARK: the helps inside Add credential and Connect agent

    @Test("Add credential asks for a different provider when exactly one provider has a login, on the checklist only")
    func addCredentialHint() async {
        let none = await Points.checklist()
        #expect(SetupChecklistHelp.addCredentialHint(none) == nil)

        let one = await Points.checklist([Points.claude])
        #expect(SetupChecklistHelp.addCredentialHint(one)
            == "Pick a different provider from Claude, so one agent can review the other’s work.")

        let sameProvider = await Points.checklist([Points.claude, Points.claudeWork])
        #expect(SetupChecklistHelp.addCredentialHint(sameProvider)?.contains("from Claude,") == true)

        let two = await Points.checklist([Points.claude, Points.codex])
        #expect(SetupChecklistHelp.addCredentialHint(two) == nil)

        let finished = await Points.checklist([Points.claude], choice: .finished)
        #expect(SetupChecklistHelp.addCredentialHint(finished) == nil)
    }

    @Test("Connect agent prefers the next login without an agent, on the checklist only")
    func connectPreference() async {
        let twoLogins = await Points.checklist([Points.claude, Points.codex])
        #expect(SetupChecklistHelp.preferredLoginID(twoLogins) == Fixtures.loginID)

        let oneAgent = await Points.checklist([Points.claude, Points.codex], [Points.claudeAgent])
        #expect(SetupChecklistHelp.preferredLoginID(oneAgent) == Fixtures.secondLoginID)

        let finished = await Points.checklist([Points.claude, Points.codex], [Points.claudeAgent], choice: .finished)
        #expect(SetupChecklistHelp.preferredLoginID(finished) == nil)
    }

    // MARK: the words

    @Test("no sentence of the checklist uses an engine word, an em dash or the old tab name")
    func plainWords() {
        for text in SetupChecklistCopy.allTexts {
            #expect(!text.contains("—"), "\(text)")
            #expect(!text.lowercased().contains("orchestrator"), "\(text)")
            #expect(text.range(of: #"\bboard\b"#, options: .regularExpression) == nil || text.contains("task board"), "\(text)")
            #expect(BannedTerms.found(in: text).isEmpty, "\(text)")
        }
    }
}
