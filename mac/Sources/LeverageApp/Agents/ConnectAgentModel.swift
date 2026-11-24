import Foundation
import LeverageKit
import Observation

/// Connects an agent on a login or shows a one-time landing prompt.
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
        /// A seat that connects by prompt: show the prompt it will use to join.
        case shown
        /// A seat the app runs: connected, and started by Leverage.
        case done
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

    /// The roles Connect offers, in the order shown by the picker (GA-10).
    static let roles: [SeatRole] = [.general, .builder, .reviewer, .planner, .orchestrator]

    var mode: Mode = .runOnLogin {
        didSet { if mode != oldValue { clearFormLines() } }
    }
    var role: SeatRole = .general {
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
    private(set) var prompt: LandingPromptModel?
    private var allLogins: [LoginChoice] = []

    @ObservationIgnored private let api: any OwnerAPI
    @ObservationIgnored private let copy: @MainActor (String) -> Void
    @ObservationIgnored private let onConnected: @MainActor () -> Void
    @ObservationIgnored private let testedProviders: [Provider]
    @ObservationIgnored private var sent: (request: ConnectSeatRequest, key: IdempotencyKey)?
    @ObservationIgnored private let generalTestedProviders: [Provider]
    @ObservationIgnored private var finished = false

    init(
        api: any OwnerAPI, copy: @escaping @MainActor (String) -> Void, onConnected: @escaping @MainActor () -> Void,
        testedProviders: [Provider] = ContractLists.orchestratorTestedProviders,
        generalTestedProviders: [Provider] = ContractLists.generalTestedProviders
    ) {
        self.api = api
        self.copy = copy
        self.onConnected = onConnected
        self.testedProviders = testedProviders
        self.generalTestedProviders = generalTestedProviders
    }

    /// Whether the chosen General or Orchestrator seat has eval coverage (GA-11, RV-5).
    var showsNotTestedNote: Bool {
        if role == .general {
            return chosenProvider.map { !generalTestedProviders.contains($0) } ?? false
        }
        return role == .orchestrator
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
            let outcome = try await api.connectSeat(request, key: key)
            guard !finished else { return }
            guard let answer = try outcome.completedResult() else { throw LeverageClientError.invalidBody }
            sent = nil
            if let selectedConnection {
                let prompt = LandingPromptModel(api: api, copy: copy, seatID: answer.seatID, connection: selectedConnection)
                self.prompt = prompt
                phase = .shown
                onConnected()
                await prompt.issue()
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

    /// Closing the sheet drops the prompt and its token.
    func finish() {
        finished = true
        prompt?.close()
        prompt = nil
    }
}
