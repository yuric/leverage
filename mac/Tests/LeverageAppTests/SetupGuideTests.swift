import Foundation
import LeverageKit
import LeverageTestSupport
import Testing

@testable import LeverageApp

private typealias Fixtures = AgentFixtures

/// Made-up workspaces at each point of setup, as the mockup's inspector names them.
enum SetupPoints {
    static let claude = Fixtures.credential(Fixtures.loginID, name: "Personal", provider: .claude, position: 1)
    static let claudeWork = Fixtures.credential(Fixtures.secondLoginID, name: "Work", provider: .claude, position: 2)
    static let codex = Fixtures.credential(Fixtures.secondLoginID, name: "Team", provider: .codex, position: 2)
    static let claudeAgent = Fixtures.seat(
        Fixtures.builderID, name: "Claude, Personal", role: .general, credential: Fixtures.loginID)
    static let codexAgent = Fixtures.seat(
        Fixtures.reviewerID, name: "Codex, Team", role: .general, provider: .codex, credential: Fixtures.secondLoginID)
    static let taskID = UUID(uuidString: "12121212-3434-4565-8787-909090909090")!

    static func task(_ state: TaskState, title: String = "Pocket to-do") -> BoardTask {
        BoardTask(task: TaskSummary(
            id: taskID, title: title, details: nil, state: state, round: 0,
            holderSeatID: state == .working ? Fixtures.builderID : nil, builderSeatID: Fixtures.builderID,
            workReference: nil, priority: .normal))
    }

    static func facts(
        _ credentials: [CredentialWithReading] = [], _ seats: [Seat] = [], _ tasks: [BoardTask] = []
    ) -> SetupModel.Facts {
        SetupModel.Facts(credentials: credentials.map(\.credential), seats: seats, tasks: tasks.map(\.task))
    }

    static let fresh = facts()
    static let oneLogin = facts([claude])
    static let twoLoginsOneProvider = facts([claude, claudeWork])
    static let twoLogins = facts([claude, codex])
    static let oneAgent = facts([claude, codex], [claudeAgent])
    static let agents = facts([claude, codex], [claudeAgent, codexAgent])
    static let running = facts([claude, codex], [claudeAgent, codexAgent], [task(.working)])
    static let done = facts([claude, codex], [claudeAgent, codexAgent], [task(.done)])

    /// A setup model on the checklist with these logins, agents and tasks.
    @MainActor
    static func checklist(
        _ credentials: [CredentialWithReading] = [], _ seats: [Seat] = [], _ tasks: [BoardTask] = [],
        choice: SetupChoice = .skipped
    ) async -> SetupModel {
        let owner = Fixtures.owner(
            seats: SeatsList(seats: seats, asOfSeq: 4), credentials: CredentialsList(credentials: credentials, asOfSeq: 4),
            board: Board(tasks: tasks, asOfSeq: 4, reviewerSeatExists: true))
        let model = SetupModel(api: owner, store: FakeSetupProgressStore(stored: choice))
        await model.load()
        return model
    }
}

/// What the spotlight lights and what its note says (docs/onboarding/checklist-spotlight.html, `guideSpec()`).
@MainActor
@Suite("SetupGuide")
struct SetupGuideTests {
    private typealias Points = SetupPoints

    struct Row: CustomTestStringConvertible, Sendable {
        let name: String
        let facts: SetupModel.Facts
        let place: Navigator.Place
        let target: SpotlightTarget?
        let side: SetupGuideNote.Side?
        let step: Int?
        let title: String?
        let body: String?
        let offersFinish: Bool

        var testDescription: String { name }
    }

    nonisolated static let rows: [Row] = [
        Row(
            name: "fresh, on the task board", facts: Points.fresh, place: .board, target: .credentialsTab, side: .right,
            step: 1, title: "Start here: add a login",
            body: "Agents run on a subscription you already have, like Claude or Codex. Until one is added, no task can run.",
            offersFinish: false),
        Row(
            name: "fresh, on Credentials", facts: Points.fresh, place: .credentials, target: .addCredential, side: .below,
            step: 1, title: "Add your first login",
            body: "Pick the provider, name it and sign in. Leverage checks that it is installed, signed in and answering.",
            offersFinish: false),
        Row(
            name: "one login, on Agents", facts: Points.oneLogin, place: .agents, target: .credentialsTab, side: .right,
            step: 1, title: "One more login to add",
            body: "It has to come from a different provider than Claude, so one agent can review the other’s work.",
            offersFinish: false),
        Row(
            name: "one login, on Credentials", facts: Points.oneLogin, place: .credentials, target: .addCredential,
            side: .below, step: 1, title: "Now a second, from a different provider",
            body: "An agent from another provider reviews the work before it counts as done. Pick anything but Claude.",
            offersFinish: false),
        Row(
            name: "two logins of one provider, on Credentials", facts: Points.twoLoginsOneProvider, place: .credentials,
            target: .addCredential, side: .below, step: 1, title: "Now a second, from a different provider",
            body: "An agent from another provider reviews the work before it counts as done. Pick anything but Claude.",
            offersFinish: false),
        Row(
            name: "two logins, on Credentials", facts: Points.twoLogins, place: .credentials, target: .agentsTab,
            side: .right, step: 2, title: "Next: connect your agents",
            body: "A login is only a way in. An agent is what does the work. Connect one for each login.",
            offersFinish: false),
        Row(
            name: "two logins, on Agents", facts: Points.twoLogins, place: .agents, target: .connectAgent, side: .below,
            step: 2, title: "Connect an agent",
            body: "It is filled in for you to run on Claude, Personal. General means it can build, review and check tasks.",
            offersFinish: false),
        Row(
            name: "one agent, on the task board", facts: Points.oneAgent, place: .board, target: .agentsTab, side: .right,
            step: 2, title: "Connect the second agent", body: "With two agents, one builds and the other reviews.",
            offersFinish: false),
        Row(
            name: "one agent, on Agents", facts: Points.oneAgent, place: .agents, target: .connectAgent, side: .below,
            step: 2, title: "One more, on Codex, Team",
            body: "It is filled in for you to run on Codex, Team. General means it can build, review and check tasks.",
            offersFinish: false),
        Row(
            name: "agents connected, on Agents", facts: Points.agents, place: .agents, target: .addTask, side: .below,
            step: 3, title: "Give them something to do",
            body: "Use Add task to write what should get done. One agent builds it and the other reviews it.",
            offersFinish: false),
        Row(
            name: "agents connected, on Rules", facts: Points.agents, place: .rules, target: .addTask,
            side: .below, step: 3, title: "Give them something to do",
            body: "Use Add task to write what should get done. One agent builds it and the other reviews it.",
            offersFinish: false),
        Row(
            name: "first task running, on the task board", facts: Points.running, place: .board, target: nil, side: nil,
            step: nil, title: nil, body: nil, offersFinish: false),
        Row(
            name: "first task running, on Agents", facts: Points.running, place: .agents, target: nil, side: nil,
            step: nil, title: nil, body: nil, offersFinish: false),
        Row(
            name: "first task done, on the task board", facts: Points.done, place: .board, target: .doneTask, side: .left,
            step: 4, title: "Your first task is done",
            body: "Open the card any time to see how it got there, and who reviewed it.",
            offersFinish: true),
        Row(
            name: "first task done, on Agents", facts: Points.done, place: .agents, target: nil, side: nil, step: nil,
            title: nil, body: nil, offersFinish: false),
    ]

    @Test("each point of setup lights one control with its note", arguments: rows)
    func table(_ row: Row) {
        let note = SetupGuide.note(for: row.facts, place: row.place, taskPageOpen: false)
        #expect(note?.target == row.target)
        #expect(note?.side == row.side)
        #expect(note?.step == row.step)
        #expect(note?.title == row.title)
        #expect(note?.body == row.body)
        #expect((note?.offersFinish ?? false) == row.offersFinish)
        if let note {
            #expect(note.stepLine == "Step \(note.step) of 4")
            #expect(note.accessibilityLabel == "\(note.title). \(note.body)")
        }
    }

    @Test("nothing is lit while a task's page is open, at any point of setup", arguments: rows)
    func taskPageOpen(_ row: Row) {
        #expect(SetupGuide.note(for: row.facts, place: row.place, taskPageOpen: true) == nil)
    }

    @Test("a second agent with no login left to fill in says so plainly")
    func connectWithoutAFreeLogin() {
        // Both logins already have an agent, but both agents run on one provider.
        let sameProvider = Fixtures.seat(
            UUID(), name: "Claude again", role: .general, credential: Fixtures.secondLoginID)
        let facts = Points.facts([Points.claude, Points.codex], [Points.claudeAgent, sameProvider])
        #expect(facts.nextLoginWithoutAgent == nil)
        let note = SetupGuide.note(for: facts, place: .agents, taskPageOpen: false)
        #expect(note?.title == "One more, on your other login")
        #expect(note?.body == "Pick the login it runs on. General means it can build, review and check tasks.")
    }

    @Test("the last note never names which agent built or reviewed the task")
    func lastNoteNamesNoAgent() throws {
        let note = try #require(SetupGuide.note(for: Points.done, place: .board, taskPageOpen: false))
        #expect(!note.body.contains("Claude"))
        #expect(!note.body.contains("Codex"))
    }

    // MARK: when the spotlight is drawn at all

    @Test("the spotlight is drawn on the checklist while it is on and no sheet is open")
    func drawnWhenOn() async {
        let setup = await Points.checklist([Points.claude])
        let navigator = Navigator()
        #expect(setup.presentation == .checklist)
        #expect(SetupGuide.visibleNote(setup, navigator: navigator)?.target == .credentialsTab)
    }

    @Test("Not now hides the spotlight and Show me brings it back")
    func notNowAndShowMe() async {
        let setup = await Points.checklist([Points.claude])
        let navigator = Navigator()
        setup.notNow()
        #expect(!setup.spotlightOn)
        #expect(SetupGuide.visibleNote(setup, navigator: navigator) == nil)
        setup.showMe()
        #expect(setup.spotlightOn)
        #expect(SetupGuide.visibleNote(setup, navigator: navigator) != nil)
    }

    @Test("an open sheet hides the spotlight until it closes")
    func sheetHides() async {
        let setup = await Points.checklist([Points.claude])
        let navigator = Navigator()
        setup.isSheetOpen = true
        #expect(SetupGuide.visibleNote(setup, navigator: navigator) == nil)
        setup.isSheetOpen = false
        #expect(SetupGuide.visibleNote(setup, navigator: navigator) != nil)
    }

    @Test("a task's page hides the spotlight")
    func taskPageHides() async {
        let setup = await Points.checklist([Points.claude])
        let navigator = Navigator()
        navigator.open(task: UUID())
        #expect(SetupGuide.visibleNote(setup, navigator: navigator) == nil)
        navigator.closeTask()
        #expect(SetupGuide.visibleNote(setup, navigator: navigator) != nil)
    }

    @Test("nothing is drawn without the checklist: after setup, in the assistant, and before the first read")
    func nothingWithoutChecklist() async {
        let finished = await Points.checklist([Points.claude], choice: .finished)
        #expect(finished.presentation == .none)
        #expect(SetupGuide.visibleNote(finished, navigator: Navigator()) == nil)

        let assistant = await Points.checklist(choice: .started)
        #expect(assistant.presentation == .assistant)
        #expect(SetupGuide.visibleNote(assistant, navigator: Navigator()) == nil)

        let undecided = SetupModel(api: FakeOwnerAPI(), store: FakeSetupProgressStore())
        #expect(SetupGuide.visibleNote(undecided, navigator: Navigator()) == nil)
    }

    @Test("Finish setup on the last note ends the checklist and puts the spotlight away")
    func finishFromNote() async {
        let setup = await Points.checklist(
            [Points.claude, Points.codex], [Points.claudeAgent, Points.codexAgent], [Points.task(.working)])
        #expect(setup.presentation == .checklist)
        setup.finishChecklist()
        #expect(setup.presentation == .none)
        #expect(SetupGuide.visibleNote(setup, navigator: Navigator()) == nil)
    }

    // MARK: where the arrow and the note go

    @Test("a control is lit only while it is wholly in the window and, for a card, in the visible lanes")
    func visibility() {
        let window = CGRect(x: 0, y: 0, width: 1000, height: 700)
        let card = CGRect(x: 600, y: 300, width: 140, height: 60)
        #expect(SpotlightLayout.isVisible(card, in: window, clippedBy: nil))
        #expect(!SpotlightLayout.isVisible(card.offsetBy(dx: 500, dy: 0), in: window, clippedBy: nil))
        #expect(!SpotlightLayout.isVisible(.zero, in: window, clippedBy: nil))
        let lanes = CGRect(x: 220, y: 320, width: 760, height: 360)
        #expect(!SpotlightLayout.isVisible(card, in: window, clippedBy: lanes), "half under the checklist card")
        #expect(SpotlightLayout.isVisible(card.offsetBy(dx: 0, dy: 100), in: window, clippedBy: lanes))
    }

    @Test("the hole is the control grown by 6 points on each side")
    func hole() {
        let hole = SpotlightLayout.hole(around: CGRect(x: 100, y: 50, width: 80, height: 30))
        #expect(hole == CGRect(x: 94, y: 44, width: 92, height: 42))
    }

    @Test("a note to the right sits beside the control, with the arrow between them")
    func placeRight() {
        let hole = CGRect(x: 10, y: 200, width: 170, height: 44)
        let placed = SpotlightLayout.place(
            hole: hole, side: .right, note: CGSize(width: 292, height: 140), in: CGSize(width: 1000, height: 700))
        #expect(placed.arrow == CGPoint(x: 188, y: 208))
        #expect(placed.note == CGPoint(x: 224, y: 178))
    }

    @Test("a note below sits under the control, its right edge on the control's, kept inside the window")
    func placeBelow() {
        let hole = CGRect(x: 880, y: 10, width: 100, height: 48)
        let placed = SpotlightLayout.place(
            hole: hole, side: .below, note: CGSize(width: 292, height: 140), in: CGSize(width: 1000, height: 700))
        #expect(placed.arrow == CGPoint(x: 916, y: 66))
        #expect(placed.note == CGPoint(x: 688, y: 102))

        let atLeft = SpotlightLayout.place(
            hole: CGRect(x: 0, y: 10, width: 60, height: 40), side: .below, note: CGSize(width: 292, height: 140),
            in: CGSize(width: 1000, height: 700))
        #expect(atLeft.note.x == 12)
    }

    @Test("a note to the left sits before the control and never runs off the bottom")
    func placeLeft() {
        let hole = CGRect(x: 700, y: 640, width: 220, height: 50)
        let placed = SpotlightLayout.place(
            hole: hole, side: .left, note: CGSize(width: 292, height: 140), in: CGSize(width: 1000, height: 700))
        #expect(placed.arrow == CGPoint(x: 664, y: 651))
        #expect(placed.note == CGPoint(x: 364, y: 548))
    }
}
