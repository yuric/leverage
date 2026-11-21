import Foundation
import LeverageKit
import Observation

/// The Connect sheet (MA-10, MA-12, MA-27, IN-29, Q-15): either "Run it on
/// one of my logins" (role, login, name), where leverage starts the agent
/// and no token is shown, or "It connects on its own" (role, name, provider),
/// where the token is shown once and, below it, a landing prompt to paste
/// into the agent.
///
/// The token is kept only while the sheet shows it, is never written
/// anywhere but the pasteboard when the owner chooses Copy, and is dropped
/// by `finish()`. The landing prompt comes from `get_landing_prompt`; a text
/// that holds the token or anything shaped like one is refused, never shown
/// or copied.
@MainActor
@Observable
final class ConnectAgentModel {
    enum Mode: Equatable, Sendable {
        case runOnLogin
        case connectsOnItsOwn
    }

    enum Phase: Equatable, Sendable {
        case editing
        case connecting
        /// A seat that connects on its own: its token is on screen, once.
        case shown
        /// A seat the app runs: connected, and started by leverage.
        case done
    }

    enum Landing: Equatable, Sendable {
        case none
        case loading
        case ready(String)
        case failed(String)
    }

    /// One login the owner can pick.
    struct LoginChoice: Identifiable, Equatable, Sendable {
        let id: UUID
        let provider: Provider
        /// "Claude, Personal"
        let label: String

        init(id: UUID, provider: Provider, label: String) {
            self.id = id
            self.provider = provider
            self.label = label
        }

        /// A login of the Credentials list, labelled by its provider and name, never its email.
        init(_ credential: Credential) {
            self.init(id: credential.id, provider: credential.provider, label: ProviderNames.account(credential))
        }
    }

    /// The roles Connect offers (MA-10): the planner and the orchestrator are connected like a builder.
    static let roles: [SeatRole] = [.builder, .reviewer, .planner, .orchestrator]

    var mode: Mode = .runOnLogin {
        didSet { if mode != oldValue { clearFormLines() } }
    }
    var role: SeatRole = .builder {
        didSet {
            if role != oldValue { clearFormLines() }
            keepALoginPicked()
        }
    }
    var credentialID: UUID?
    var name = "" {
        didSet { if name != oldValue { nameLine = nil } }
    }
    var provider: Provider = .claude
    var strengthRank = AgentStrength.standard.rawValue
    var connection: LandingPromptConnection = .http
    var modelName = ""
    var effort = ""

    private(set) var phase: Phase = .editing
    private(set) var nameLine: String?
    private(set) var failure: String?
    private(set) var shownToken: String?
    private(set) var tokenGone = false
    private(set) var landing: Landing = .none
    private(set) var copiedToken = false
    private(set) var copiedPrompt = false
    private(set) var copiedMCPSettings = false
    private(set) var shownConnection: LandingPromptConnection?
    private(set) var mcpConfiguration: MCPSettings?
    var mcpSettings: String? { mcpConfiguration?.json }
    private var allLogins: [LoginChoice] = []

    @ObservationIgnored private let api: any OwnerAPI
    @ObservationIgnored private let copy: @MainActor (String) -> Void
    @ObservationIgnored private let apiURL: @MainActor () async -> URL?
    @ObservationIgnored private let onConnected: @MainActor () -> Void
    @ObservationIgnored private let testedProviders: [Provider]
    @ObservationIgnored private var sent: (request: ConnectSeatRequest, key: IdempotencyKey)?
    @ObservationIgnored private var connectedSeatID: UUID?
    @ObservationIgnored private var finished = false

    init(
        api: any OwnerAPI, copy: @escaping @MainActor (String) -> Void, onConnected: @escaping @MainActor () -> Void,
        testedProviders: [Provider] = ContractLists.orchestratorTestedProviders,
        apiURL: @escaping @MainActor () async -> URL? = { nil }
    ) {
        self.api = api
        self.copy = copy
        self.onConnected = onConnected
        self.testedProviders = testedProviders
        self.apiURL = apiURL
    }

    /// Whether the sheet says an orchestrator is not tested for checking tasks (RV-5).
    var showsNotTestedNote: Bool {
        role == .orchestrator
            && OrchestratorTesting.isUntested(
                provider: chosenProvider, model: modelName, connectsOnItsOwn: mode == .connectsOnItsOwn,
                tested: testedProviders)
    }

    // MARK: the form

    /// The logins the role can run on: a Gemini login is left out for a
    /// Reviewer, which the runner cannot do yet (CL-8).
    var logins: [LoginChoice] {
        role == .reviewer ? allLogins.filter { $0.provider != .gemini } : allLogins
    }

    var geminiHiddenForReviewer: Bool {
        role == .reviewer && allLogins.contains { $0.provider == .gemini }
    }

    /// The provider whose tool the agent will run: the picked login's, or
    /// the one chosen for an agent that connects on its own.
    var chosenProvider: Provider? {
        switch mode {
        case .runOnLogin: logins.first { $0.id == credentialID }?.provider
        case .connectsOnItsOwn: provider
        }
    }

    /// Effort is asked for only where the tool is given one.
    var offersEffort: Bool { chosenProvider.map(ProviderCatalog.takesEffort) ?? true }

    /// The owner chose to run the agent on a login, and there is none to run it on.
    var needsLogin: Bool { mode == .runOnLogin && logins.isEmpty }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var isBusy: Bool { phase == .connecting }

    var canConnect: Bool {
        phase == .editing && !finished && !trimmedName.isEmpty
            && AgentStrength(rawValue: strengthRank) != nil
            && (mode == .connectsOnItsOwn || credentialID != nil)
    }

    private func clearFormLines() {
        failure = nil
    }

    private func keepALoginPicked() {
        if let current = credentialID, logins.contains(where: { $0.id == current }) { return }
        credentialID = logins.first?.id
    }

    /// Reads the logins that can be picked.
    func load() async {
        do {
            let list = try await api.credentials()
            allLogins = list.credentials.map(\.credential).filter { $0.kind == .login }.map(LoginChoice.init)
            keepALoginPicked()
        } catch is CancellationError {
            return
        } catch {
            failure = ShellCopy.sentence(for: error).text
        }
    }

    // MARK: connecting

    private func makeRequest() -> ConnectSeatRequest? {
        let typed = trimmedName
        let modelText = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        let effortText = offersEffort ? effort.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        switch mode {
        case .runOnLogin:
            guard let login = logins.first(where: { $0.id == credentialID }) else { return nil }
            return ConnectSeatRequest(
                name: typed, role: role, provider: login.provider, model: modelText, effort: effortText,
                strengthRank: strengthRank, credentialID: login.id)
        case .connectsOnItsOwn:
            return ConnectSeatRequest(
                name: typed, role: role, provider: provider, model: modelText, effort: effortText,
                strengthRank: strengthRank, credentialID: nil)
        }
    }

    /// Connect. The same form pressed again after the network failed sends the
    /// same command under the same key; a changed form gets a new key.
    func connect() async {
        guard canConnect, let request = makeRequest() else { return }
        phase = .connecting
        failure = nil
        nameLine = nil
        let selectedConnection = request.credentialID == nil ? connection : nil
        let key = (sent?.request == request ? sent?.key : nil) ?? IdempotencyKey()
        sent = (request, key)
        do {
            let address = selectedConnection == .mcp ? await apiURL() : nil
            guard !finished else { return }
            let outcome = try await api.connectSeat(request, key: key)
            guard !finished else { return }
            guard let answer = try outcome.completedResult() else { throw LeverageClientError.invalidBody }
            sent = nil
            let token: String?
            let alreadyConnected: Bool
            switch answer {
            case .shown(let connected):
                connectedSeatID = connected.seatID
                token = connected.seatToken
                alreadyConnected = false
            case .repeated(let repeated):
                connectedSeatID = repeated.seatID
                token = nil
                alreadyConnected = true
            }
            if let selectedConnection, token != nil || alreadyConnected {
                shownToken = token
                tokenGone = alreadyConnected
                shownConnection = selectedConnection
                if let address {
                    mcpConfiguration = MCPSettings(apiURL: address, role: request.role)
                }
                phase = .shown
                onConnected()
                await fetchLandingPrompt()
            } else {
                phase = .done
                onConnected()
            }
        } catch is CancellationError {
            phase = .editing
        } catch {
            phase = .editing
            if CommandKey.wasAnswered(error) { sent = nil }
            if case LeverageClientError.refused(let refusal) = error, refusal.code == .duplicateName {
                nameLine = ShellCopy.refusalDuplicateName.text
            } else {
                failure = ShellCopy.sentence(for: error).text
            }
        }
    }

    // MARK: the token and the landing prompt

    private func fetchLandingPrompt() async {
        guard let seatID = connectedSeatID, let shownConnection else { return }
        landing = .loading
        do {
            let prompt = try await api.landingPrompt(seatID: seatID, connection: shownConnection)
            guard !finished else { return }
            if prompt.connection != shownConnection || TokenShape.isIn(prompt.text)
                || shownToken.map({ prompt.text.contains($0) }) == true
            {
                landing = .failed(ShellCopy.somethingWentWrong.text)
            } else {
                landing = .ready(prompt.text)
            }
        } catch is CancellationError {
            landing = .none
        } catch {
            if !finished { landing = .failed(ShellCopy.sentence(for: error).text) }
        }
    }

    func retryLandingPrompt() async {
        guard phase == .shown else { return }
        await fetchLandingPrompt()
    }

    func copyToken() {
        guard let token = shownToken else { return }
        copy(token)
        copiedToken = true
    }

    func copyLandingPrompt() {
        guard case .ready(let text) = landing else { return }
        copy(text)
        copiedPrompt = true
    }

    func copyMCPSettings() {
        guard let mcpSettings else { return }
        copy(mcpSettings)
        copiedMCPSettings = true
    }

    /// Done: the token and the connection details are forgotten.
    func finish() {
        finished = true
        connectedSeatID = nil
        shownConnection = nil
        mcpConfiguration = nil
        copiedMCPSettings = false
        shownToken = nil
        tokenGone = false
        landing = .none
        copiedToken = false
        copiedPrompt = false
    }
}
