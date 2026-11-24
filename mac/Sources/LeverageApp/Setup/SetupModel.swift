import Foundation
import LeverageKit
import Observation

/// First-run setup (docs/onboarding/PRD.md): what is true in the workspace,
/// and whether the window shows the setup assistant, the setup checklist or
/// neither.
///
/// The four steps are never stored. They are read from the logins, the
/// agents and the tasks each time, so a step is done when it is true,
/// whichever screen made it true. Only the owner's choice is kept, in the
/// runtime's `SetupProgressStoring`: the assistant was opened, left, or setup
/// is over.
///
/// The presentation is decided once, by the first read after sign-in, and
/// after that it changes only when the owner leaves or finishes the
/// assistant, or finishes or hides the checklist. A step turning true never
/// moves the owner to another screen by itself.
@MainActor
@Observable
final class SetupModel {
    /// What the signed-in window shows.
    enum Presentation: Equatable, Sendable {
        /// The first read has not answered yet: nothing is drawn.
        case undecided
        /// The setup assistant fills the window; no side pane.
        case assistant
        /// The app, with the setup checklist on the task board and the spotlight.
        case checklist
        /// The app as it is without setup.
        case none
    }

    /// The four steps, in order.
    enum Step: Int, CaseIterable, Sendable {
        case logins = 1
        case agents
        case firstTask
        case done
    }

    /// A login the owner added: "Claude, Personal".
    struct Login: Identifiable, Equatable, Sendable {
        let id: UUID
        let provider: Provider
        let label: String
    }

    /// A connected agent.
    struct Agent: Identifiable, Equatable, Sendable {
        let id: UUID
        let name: String
        let provider: Provider
        /// The login it runs on; nil for an agent connected by prompt.
        let credentialID: UUID?
    }

    /// A task by its id and title: the finished one for the last step's
    /// spotlight, and the sent one for the checklist's third and fourth steps.
    struct DoneTask: Equatable, Sendable {
        let id: UUID
        let title: String
    }

    /// What is true in the workspace.
    struct Facts: Equatable, Sendable {
        /// Logins only, in the handoff order. An API token runs no agent.
        var logins: [Login] = []
        var agents: [Agent] = []
        /// A task has left Ideas and Backlog: it was sent to agents.
        var hasSentTask = false
        /// Any task at all, in any lane.
        var hasAnyTask = false
        /// The first finished task the board lists.
        var doneTask: DoneTask?
        /// The first task the board lists that was sent to agents, done or not.
        var sentTask: DoneTask?

        /// The review rule ships on, so setup asks for two providers.
        static let providersNeeded = 2

        var loginProviders: [Provider] { Self.distinct(logins.map(\.provider)) }
        var agentProviders: [Provider] { Self.distinct(agents.map(\.provider)) }

        func isDone(_ step: Step) -> Bool {
            switch step {
            case .logins: loginProviders.count >= Self.providersNeeded
            case .agents: agentProviders.count >= Self.providersNeeded
            case .firstTask: hasSentTask
            case .done: doneTask != nil
            }
        }

        var doneCount: Int { Step.allCases.filter(isDone).count }
        var allDone: Bool { doneCount == Step.allCases.count }
        /// The first step that is not done; nil when all four are.
        var current: Step? { Step.allCases.first { !isDone($0) } }
        /// Nothing has been set up: no login, no agent and no task.
        var isEmpty: Bool { logins.isEmpty && agents.isEmpty && !hasAnyTask }
        /// Everything the assistant asks for is there.
        var assistantHasNothingLeft: Bool { isDone(.logins) && isDone(.agents) && isDone(.firstTask) }
        /// A name for a new agent on `login`: the login's own name, or the
        /// first of "{login} 2", "{login} 3" that no agent has and `taken`
        /// does not hold. The server lets two agents share a name, so the app
        /// keeps them apart.
        func freeAgentName(for login: Login, besides taken: [String] = []) -> String {
            let used = Set(agents.map(\.name) + taken)
            if !used.contains(login.label) { return login.label }
            var copy = 2
            while used.contains("\(login.label) \(copy)") { copy += 1 }
            return "\(login.label) \(copy)"
        }

        /// The first login no agent runs on, in the handoff order.
        var nextLoginWithoutAgent: Login? {
            logins.first { login in !agents.contains { $0.credentialID == login.id } }
        }

        private static func distinct(_ providers: [Provider]) -> [Provider] {
            var seen: [Provider] = []
            for provider in providers where !seen.contains(provider) { seen.append(provider) }
            return seen
        }

        init() {}

        /// The facts of one read of the Credentials list, the roster and the board.
        init(credentials: [Credential], seats: [Seat], tasks: [TaskSummary]) {
            logins = credentials.filter { $0.kind == .login }.sorted { $0.position < $1.position }
                .map { Login(id: $0.id, provider: $0.provider, label: ProviderNames.account($0)) }
            agents = seats.filter { $0.removedAt == nil }
                .map { Agent(id: $0.id, name: $0.name, provider: $0.provider, credentialID: $0.credentialID) }
            hasAnyTask = !tasks.isEmpty
            hasSentTask = tasks.contains { Self.sentStates.contains($0.state) }
            doneTask = tasks.first { $0.state == .done }.map { DoneTask(id: $0.id, title: $0.title) }
            sentTask = tasks.first { Self.sentStates.contains($0.state) }.map { DoneTask(id: $0.id, title: $0.title) }
        }

        private static let sentStates: Set<TaskState> = [.ready, .working, .inReview, .finishing, .done]
    }

    private(set) var presentation: Presentation = .undecided
    private(set) var facts = Facts()
    /// The task the assistant sent, for one line on the task board; nil once dismissed.
    private(set) var sentTaskTitle: String?
    /// Whether the spotlight is on. "Not now" turns it off and "Show me" on
    /// again; it is on again at the next launch.
    var spotlightOn = true
    /// A sheet is open over the window, so the spotlight steps aside. The
    /// screen that presents a sheet sets it.
    var isSheetOpen = false

    @ObservationIgnored private let api: any OwnerAPI
    @ObservationIgnored private let store: any SetupProgressStoring
    @ObservationIgnored private let noteRead: @MainActor (Int) -> Void
    @ObservationIgnored private let log = Log(component: "setup")
    @ObservationIgnored private var subscription: EventFeed.Subscription?
    @ObservationIgnored private var generation = 0
    /// The first read failed and the app was shown as it is.
    @ObservationIgnored private(set) var shownWithoutFacts = false

    init(api: any OwnerAPI, store: any SetupProgressStoring, noteRead: @escaping @MainActor (Int) -> Void = { _ in }) {
        self.api = api
        self.store = store
        self.noteRead = noteRead
    }

    // MARK: reading

    /// What the first read decides: the presentation, and the choice to keep, if any.
    static func entry(choice: SetupChoice, facts: Facts) -> (presentation: Presentation, keep: SetupChoice?) {
        switch choice {
        case .finished:
            return (.none, nil)
        case .skipped:
            return facts.allDone ? (.none, .finished) : (.checklist, nil)
        case .started:
            return facts.assistantHasNothingLeft ? (.none, .finished) : (.assistant, nil)
        case .notChosen:
            // A workspace with nothing in it is new. One that has something was
            // set up before setup existed: it gets the checklist, never a takeover.
            if facts.isEmpty { return (.assistant, .started) }
            return facts.allDone ? (.none, .finished) : (.checklist, nil)
        }
    }

    /// Reads the logins, the agents and the board, and decides the
    /// presentation the first time they answer. When the first read fails the
    /// app shows as it is, and a later read never opens the assistant over it.
    func load() async {
        generation += 1
        let mine = generation
        do {
            let credentials = try await api.credentials()
            let seats = try await api.seats()
            let board = try await api.board()
            guard mine == generation else { return }
            facts = Facts(
                credentials: credentials.credentials.map(\.credential), seats: seats.seats,
                tasks: board.tasks.map(\.task))
            // Only the first read seeds the events tail; later ones would rewind it.
            if presentation == .undecided { noteRead(min(credentials.asOfSeq, seats.asOfSeq, board.asOfSeq)) }
            decide()
        } catch is CancellationError {
            return
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch {
            guard mine == generation, presentation == .undecided else { return }
            shownWithoutFacts = true
            presentation = .none
        }
    }

    private func decide() {
        guard presentation == .undecided || shownWithoutFacts else { return }
        let entry = Self.entry(choice: store.load(), facts: facts)
        if shownWithoutFacts {
            shownWithoutFacts = false
            // The owner is already in the app: the checklist, not a takeover.
            presentation = entry.presentation == .assistant ? .checklist : entry.presentation
            if entry.presentation == .assistant { keep(.skipped) } else if let choice = entry.keep { keep(choice) }
            return
        }
        presentation = entry.presentation
        if let choice = entry.keep { keep(choice) }
    }

    /// Whether setup still needs the workspace read: before the first
    /// decision, while the assistant or the checklist shows, and after a
    /// failed first read, which a later read may turn into the checklist
    /// (OB-8). Once setup is over nothing is read again.
    var needsReading: Bool { presentation != .none || shownWithoutFacts }

    /// Reads again each time the events tail delivers a batch, while setup
    /// needs it.
    func attach(to feed: EventFeed) {
        subscription?.cancel()
        subscription = feed.subscribe { [weak self] _ in
            guard let self, self.needsReading else { return }
            Task { await self.load() }
        }
    }

    func detach() {
        subscription?.cancel()
        subscription = nil
    }

    // MARK: the owner's choices

    /// "Set up later", and "Skip, take me to the board": the assistant closes
    /// and the checklist takes over.
    func skipAssistant() {
        guard presentation == .assistant else { return }
        presentation = .checklist
        spotlightOn = true
        keep(.skipped)
    }

    /// The assistant sent the first task: setup is over and the app shows as
    /// it is, with one line on the task board naming the task.
    func finishAssistant(sentTask title: String) {
        guard presentation == .assistant else { return }
        sentTaskTitle = title
        presentation = .none
        keep(.finished)
    }

    /// "Finish setup" after the last step, and "Hide this" before it.
    func finishChecklist() {
        guard presentation == .checklist else { return }
        presentation = .none
        keep(.finished)
    }

    func dismissSentTaskLine() { sentTaskTitle = nil }

    /// A choice that cannot be kept still holds until the app quits.
    private func keep(_ choice: SetupChoice) {
        do {
            try store.save(choice)
        } catch {
            log.warning("the setup choice could not be kept: \(error.localizedDescription)")
        }
    }
}
