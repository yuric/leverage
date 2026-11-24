import Foundation
import LeverageKit
import Observation

/// The setup assistant (docs/onboarding/setup-assistant.html): Welcome, two
/// logins, one General agent for each login, and a first task.
///
/// What is done is never kept here. It is read from `SetupModel.facts`,
/// which this model reads again after each thing it adds, so a login or an
/// agent added anywhere counts. The model keeps only what the owner is in the
/// middle of: the screen, the login being checked, the switches, and the
/// first task's choice. The work itself goes through the models of the
/// screens that already do it: `AddCredentialModel` for a login and
/// `AddTaskModel` for the task.
@MainActor
@Observable
final class SetupAssistantModel {
    /// The screens, in order.
    enum Screen: Int, CaseIterable, Sendable {
        case welcome, firstLogin, secondLogin, agents, firstTask

        /// The step of the stepper this screen belongs to.
        var stage: Stage {
            switch self {
            case .welcome: .welcome
            case .firstLogin, .secondLogin: .logins
            case .agents: .agents
            case .firstTask: .firstTask
            }
        }
    }

    /// The four steps across the top.
    enum Stage: Int, CaseIterable, Sendable {
        case welcome, logins, agents, firstTask

        var copy: SetupAssistantCopy {
            switch self {
            case .welcome: .stepWelcome
            case .logins: .stepLogins
            case .agents: .stepAgents
            case .firstTask: .stepFirstTask
            }
        }
    }

    /// One provider tile of the login screens.
    struct ProviderTile: Identifiable, Equatable, Sendable {
        let provider: Provider
        let name: String
        let tool: String
        /// Gemini builds but does not review yet.
        let note: String?
        /// A login of this provider was added: the tile cannot be picked.
        let isAdded: Bool
        var id: Provider { provider }
    }

    /// One row of the Agents screen: a login, and the General agent that runs on it.
    struct AgentRow: Identifiable, Equatable, Sendable {
        let login: SetupModel.Login
        let isOn: Bool
        let isConnected: Bool
        var isGemini: Bool { login.provider == .gemini }
        var id: UUID { login.id }
    }

    /// The wait-toned note under the agents.
    enum AgentNote: Equatable, Sendable {
        /// One provider: finished work waits for a review.
        case oneProvider
        /// Gemini and one other provider: the other reviews what Gemini builds.
        case geminiReviews(other: String)
        /// Every switch is off.
        case turnOnOne

        var text: String {
            switch self {
            case .oneProvider: SetupAssistantCopy.oneProviderNote.text
            case .geminiReviews(let other): SetupAssistantCopy.geminiReviewNote.filled(["other": other])
            case .turnOnOne: SetupAssistantCopy.turnOnOne.text
            }
        }
    }

    private(set) var screen: Screen

    // The login screens.
    /// The sign-in of the provider picked, from the pick until it added the
    /// login or the owner cancelled. A new pick is a new attempt.
    private(set) var attempt: AddCredentialModel?
    /// "I only have one subscription" is open.
    private(set) var showsOneSubscription = false

    // The Agents screen.
    private(set) var agentsOff: Set<UUID> = []
    private(set) var isStartingAgents = false
    private(set) var agentFailure: String?

    // The first task.
    private(set) var starter: StarterTask.Kind?
    private(set) var writesOwn = false
    var ownTitle = ""
    var ownCriteria = ""
    private(set) var isSending = false
    private(set) var taskFailure: String?

    @ObservationIgnored private let setup: SetupModel
    @ObservationIgnored private let api: any OwnerAPI
    @ObservationIgnored private let helper: any HelperSupervising
    @ObservationIgnored private let navigator: Navigator
    @ObservationIgnored private let timing: FollowTiming
    /// Agents connected from this screen, so a retry never sends them again
    /// even when the read after it failed.
    @ObservationIgnored private var connectedHere: Set<UUID> = []
    /// The Connect sent for a login and its key, kept until the server answered.
    @ObservationIgnored private var sentAgents: [UUID: (request: ConnectSeatRequest, key: IdempotencyKey)] = [:]
    /// The Add task form behind the first task; it keeps its keys between tries.
    @ObservationIgnored private var taskForm: AddTaskModel?

    init(
        setup: SetupModel, api: any OwnerAPI, helper: any HelperSupervising, navigator: Navigator,
        timing: FollowTiming = .normal
    ) {
        self.setup = setup
        self.api = api
        self.helper = helper
        self.navigator = navigator
        self.timing = timing
        screen = Self.opening(for: setup.facts)
    }

    var facts: SetupModel.Facts { setup.facts }

    /// Where the assistant opens: on the first thing that is not there yet.
    static func opening(for facts: SetupModel.Facts) -> Screen {
        if facts.logins.isEmpty { return .welcome }
        if !facts.isDone(.logins) { return .secondLogin }
        if !facts.isDone(.agents) { return .agents }
        return .firstTask
    }

    // MARK: moving between screens

    var stage: Stage { screen.stage }

    func isDone(_ stage: Stage) -> Bool { stage.rawValue < screen.stage.rawValue }

    /// Whether the primary button moves on (or, on the last screen, sends).
    var canContinue: Bool {
        switch screen {
        case .welcome: true
        case .firstLogin: !facts.logins.isEmpty && attempt == nil
        case .secondLogin: facts.loginProviders.count >= SetupModel.Facts.providersNeeded && attempt == nil
        case .agents: agentsStarted && !isStartingAgents
        case .firstTask: canSend
        }
    }

    /// Get started, and Continue.
    func next() {
        guard canContinue, screen != .firstTask, let following = Screen(rawValue: screen.rawValue + 1) else { return }
        go(to: following)
    }

    func back() {
        guard screen != .welcome, let previous = Screen(rawValue: screen.rawValue - 1) else { return }
        go(to: previous)
    }

    /// "Set up later", and "Skip, take me to the task board": the checklist takes over.
    func skip() {
        stopSignIn()
        setup.skipAssistant()
        navigator.show(.board)
    }

    private func go(to next: Screen) {
        stopSignIn()
        showsOneSubscription = false
        agentFailure = nil
        screen = next
    }

    // MARK: logins

    /// The four logins; an API token runs no agent, so none is offered here.
    var tiles: [ProviderTile] {
        let added = facts.loginProviders
        return ProviderNames.logins.map { provider in
            ProviderTile(
                provider: provider, name: ProviderNames.name(provider), tool: ProviderNames.tool(provider),
                note: provider == .gemini ? SetupAssistantCopy.geminiTileNote.text : nil,
                isAdded: added.contains(provider))
        }
    }

    /// The tiles show until this screen's login is there.
    var showsTiles: Bool {
        switch screen {
        case .firstLogin: facts.logins.isEmpty
        case .secondLogin: facts.loginProviders.count < SetupModel.Facts.providersNeeded
        case .welcome, .agents, .firstTask: false
        }
    }

    /// Picks a provider: a new sign-in, with its name field.
    func pick(_ provider: Provider) {
        guard showsTiles, attempt?.isWorking != true,
              let tile = tiles.first(where: { $0.provider == provider }), !tile.isAdded else { return }
        stopSignIn()
        let made = AddCredentialModel(api: api, onAdded: {}, timing: timing, helper: helper)
        made.pick(provider)
        attempt = made
    }

    /// Sign in: Add credential and the three checks. When the login is
    /// added, setup is read again so the login shows as added.
    func signIn() async {
        guard let attempt else { return }
        await attempt.signIn()
        await settle(attempt)
    }

    func retry() async {
        guard let attempt, attempt.canRetry else { return }
        await attempt.retry()
        await settle(attempt)
    }

    func install() async {
        await attempt?.install()
    }

    /// Cancel: stop following the checks, back to the tiles.
    func cancelSignIn() {
        stopSignIn()
    }

    private func stopSignIn() {
        attempt?.cancel()
        attempt = nil
    }

    /// After a login was added: read again, and keep showing the finished
    /// checks until the read shows the login, so a failed read never offers
    /// the tiles again for a login that is already there. A later read, on the
    /// next batch of events, settles it.
    private func settle(_ finished: AddCredentialModel) async {
        guard finished.step == .done else { return }
        for _ in 0..<3 {
            await setup.load()
            if facts.logins.contains(where: { $0.id == finished.credentialID }) { break }
            try? await Task.sleep(for: .milliseconds(300))
        }
        guard attempt === finished, facts.logins.contains(where: { $0.id == finished.credentialID }) else { return }
        attempt = nil
        showsOneSubscription = false
    }

    func toggleOneSubscription() {
        showsOneSubscription.toggle()
    }

    /// Continue with one provider: on to the agents.
    func continueWithOne() {
        guard screen == .secondLogin, !facts.logins.isEmpty else { return }
        go(to: .agents)
    }

    // MARK: agents

    var agentRows: [AgentRow] {
        facts.logins.map { login in
            AgentRow(login: login, isOn: !agentsOff.contains(login.id), isConnected: isConnected(login.id))
        }
    }

    private func isConnected(_ loginID: UUID) -> Bool {
        connectedHere.contains(loginID) || facts.agents.contains { $0.credentialID == loginID }
    }

    /// A switch; an agent already connected stays on.
    func setAgent(_ loginID: UUID, on: Bool) {
        guard !isStartingAgents, !isConnected(loginID) else { return }
        if on { agentsOff.remove(loginID) } else { agentsOff.insert(loginID) }
    }

    private var onRows: [AgentRow] { agentRows.filter(\.isOn) }

    /// Every login switched on has its agent.
    var agentsStarted: Bool { !onRows.isEmpty && onRows.allSatisfy(\.isConnected) }

    var canStartAgents: Bool { !isStartingAgents && !onRows.isEmpty && !agentsStarted }

    var agentNote: AgentNote? {
        let rows = onRows
        guard !rows.isEmpty else { return .turnOnOne }
        var providers: [Provider] = []
        for row in rows where !providers.contains(row.login.provider) { providers.append(row.login.provider) }
        if providers.count < SetupModel.Facts.providersNeeded { return .oneProvider }
        let others = rows.filter { !$0.isGemini }
        if rows.contains(where: \.isGemini), others.count == 1, let other = others.first {
            return .geminiReviews(other: other.login.label)
        }
        return nil
    }

    /// Start agents: one General agent for each login switched on that no
    /// agent runs on, named after the login, or "{login} 2" and on when an
    /// agent already has that name (`Facts.freeAgentName`). Connecting an
    /// agent the app runs also starts it. The first failure stops the run;
    /// what was connected stays connected, and the next press sends only the
    /// rest. A name, once sent, is kept with its key until the server answers.
    func startAgents() async {
        guard canStartAgents else { return }
        isStartingAgents = true
        agentFailure = nil
        var named: [String] = []
        for row in onRows where !row.isConnected {
            let login = row.login
            let kept = sentAgents[login.id]
            let name = kept?.request.name ?? facts.freeAgentName(for: login, besides: named)
            named.append(name)
            let request = ConnectSeatRequest(
                name: name, role: .general, provider: login.provider, model: "", effort: "",
                strengthRank: AgentStrength.standard.rawValue, credentialID: login.id)
            let key = (kept?.request == request ? kept?.key : nil) ?? IdempotencyKey()
            sentAgents[login.id] = (request, key)
            do {
                let outcome = try await api.connectSeat(request, key: key)
                guard try outcome.completedResult() != nil else { throw LeverageClientError.invalidBody }
                sentAgents[login.id] = nil
                connectedHere.insert(login.id)
            } catch is CancellationError {
                break
            } catch {
                if CommandKey.wasAnswered(error) { sentAgents[login.id] = nil }
                agentFailure = ShellCopy.sentence(for: error).text
                break
            }
        }
        await setup.load()
        isStartingAgents = false
    }

    // MARK: the first task

    func choose(_ kind: StarterTask.Kind) {
        guard !isSending else { return }
        starter = starter == kind ? nil : kind
        writesOwn = false
        taskFailure = nil
    }

    func toggleWriteOwn() {
        guard !isSending else { return }
        writesOwn.toggle()
        starter = nil
        taskFailure = nil
    }

    private var trimmedOwnTitle: String { ownTitle.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedOwnCriteria: String { ownCriteria.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// A task of the owner's own has a title and no criteria yet: it could
    /// not be sent, because a task without criteria stays in Backlog.
    var ownNeedsCriteria: Bool { writesOwn && !trimmedOwnTitle.isEmpty && trimmedOwnCriteria.isEmpty }

    var canSend: Bool {
        guard !isSending else { return false }
        if starter != nil { return true }
        return writesOwn && !trimmedOwnTitle.isEmpty && !trimmedOwnCriteria.isEmpty
    }

    /// Send to agents: Add task, then Complete contract, through the Add task
    /// form. Once it is sent setup is over and the task board shows.
    func send() async {
        guard canSend else { return }
        let form = taskForm ?? AddTaskModel(api: api, onSaved: {})
        taskForm = form
        if let starter {
            let task = StarterTask.task(starter)
            form.title = task.title.text
            form.details = task.prompt
            form.criteriaText = task.criteriaText
        } else {
            form.title = ownTitle
            form.details = ""
            form.criteriaText = ownCriteria
        }
        isSending = true
        taskFailure = nil
        await form.save()
        isSending = false
        if form.state == .saved {
            setup.finishAssistant(sentTask: form.draft.trimmedTitle)
            navigator.show(.board)
        } else {
            taskFailure = form.failure?.text
        }
    }
}
