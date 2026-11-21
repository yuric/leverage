import Foundation
import LeverageKit
import Observation

/// The Add credential pop-up (MA-17, IN-23, IN-24, CR-9, CR-13): step 1
/// picks a provider, and step 2 names and checks a login or API token.
/// A failed check stays in the pop-up with one line and a Retry. A login
/// with a missing tool also shows what leverage can install (PV-5).
///
/// After a failed check, Retry sends Add with the same credential id and a
/// new key (IN-24). An unanswered Add keeps its key. An accepted token Add
/// keeps following its existing check.
@MainActor
@Observable
final class AddCredentialModel {
    enum Step: Equatable, Sendable {
        case pickProvider
        case nameIt
        case checking
        case done
    }

    /// One provider button of step 1.
    struct ProviderChoice: Identifiable, Equatable, Sendable {
        let provider: Provider
        let name: String
        let kind: CredentialKind
        /// A provider with one sign-in for the Mac that already has a login (MA-26).
        let isAdded: Bool
        var id: Provider { provider }
    }

    /// One line of the check list.
    struct CheckLine: Identifiable, Equatable, Sendable {
        let check: HelperCheck
        let state: HelperCheckState
        let text: String
        var id: HelperCheck { check }
    }

    /// The question a missing tool asks, or the plain sentence when leverage cannot install it.
    struct InstallAsk: Equatable, Sendable {
        let text: String
        let canInstall: Bool
    }

    private(set) var step: Step = .pickProvider
    private(set) var providers: [ProviderChoice] = []
    private(set) var selection: ProviderChoice?
    var provider: Provider? { selection?.provider }
    var isToken: Bool { selection?.kind == .apiToken }
    /// Kept for Retry and cleared on Back, Cancel, or a pass.
    var token = ""
    var name = "" {
        didSet { if name != oldValue { nameLine = nil } }
    }
    private(set) var nameLine: String?
    private(set) var checks: [CheckLine] = []
    private(set) var signInNote: String?
    private(set) var installAsk: InstallAsk?
    private(set) var isInstalling = false
    private(set) var installFailure: String?
    /// The one line a failed try leaves, shown with Retry.
    private(set) var failure: String?
    private(set) var isWorking = false

    @ObservationIgnored private let api: any OwnerAPI
    @ObservationIgnored private let helper: any HelperSupervising
    @ObservationIgnored let credentialID: UUID
    @ObservationIgnored private let onAdded: @MainActor () -> Void
    @ObservationIgnored private let timing: FollowTiming
    @ObservationIgnored private var added: Set<Provider> = []
    @ObservationIgnored private var addKey: IdempotencyKey?
    @ObservationIgnored private var addedRequest: AddCredentialRequest?
    @ObservationIgnored private var pendingTokenCheck: UUID?
    @ObservationIgnored private var installKey: IdempotencyKey?
    @ObservationIgnored private var checkTask: Task<Void, Never>?
    @ObservationIgnored private var installTask: Task<Void, Never>?

    /// Only these have one sign-in for the Mac (CL-20, CL-21).
    private static let oneForTheMac: Set<Provider> = [.gemini, .grok]

    init(
        api: any OwnerAPI, credentialID: UUID = UUID(), onAdded: @escaping @MainActor () -> Void,
        timing: FollowTiming = .normal, helper: any HelperSupervising
    ) {
        self.api = api
        self.helper = helper
        self.credentialID = credentialID
        self.onAdded = onAdded
        self.timing = timing
        rebuildProviders()
    }

    // MARK: step 1

    /// Reads the logins already added, to mark the providers that can have only one.
    func load() async {
        do {
            let list = try await api.credentials()
            added = Set(list.credentials.map(\.credential.provider))
            rebuildProviders()
        } catch is CancellationError {
            return
        } catch {
            failure = ShellCopy.sentence(for: error).text
        }
    }

    private func rebuildProviders() {
        providers = ProviderNames.logins.map {
            ProviderChoice(
                provider: $0, name: ProviderNames.name($0), kind: .login,
                isAdded: Self.oneForTheMac.contains($0) && added.contains($0))
        } + ProviderCatalog.tokenEntries.map {
            ProviderChoice(provider: $0.provider, name: $0.displayName, kind: .apiToken, isAdded: false)
        }
    }

    func pick(_ choice: Provider) {
        guard step == .pickProvider,
              let selected = providers.first(where: { $0.provider == choice }), !selected.isAdded else { return }
        selection = selected
        failure = nil
        resetChecks()
        step = .nameIt
    }

    func back() {
        guard step == .nameIt, !isWorking else { return }
        discardTokenInput()
        step = .pickProvider
    }

    // MARK: step 2 and the checks

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedToken: String { token.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var nameContainsToken: Bool { !trimmedToken.isEmpty && name.contains(trimmedToken) }
    private var canStartChecks: Bool { !isWorking && (step == .nameIt || canRetry) }

    /// Whether Sign in (or Retry) can be pressed.
    var canSignIn: Bool {
        provider != nil && !isToken && !trimmedName.isEmpty && canStartChecks
    }

    var canAddToken: Bool {
        isToken && !trimmedName.isEmpty && !trimmedToken.isEmpty && canStartChecks
    }

    /// A failed try is showing, and nothing is running.
    var canRetry: Bool {
        step == .checking && failure != nil && !isWorking && (!isToken || !trimmedToken.isEmpty)
    }

    var installNote: String? {
        guard isInstalling, let provider else { return nil }
        return CredentialsCopy.installing.filled(["tool": ProviderNames.tool(provider)])
    }

    private func resetChecks() {
        guard let provider else { checks = []; return }
        if isToken {
            checks = [CheckLine(check: .tokenWorks, state: .waiting, text: AddTokenCopy.checkWorks.text)]
        } else {
            let tool = ["tool": ProviderNames.tool(provider)]
            checks = [
                CheckLine(check: .toolInstalled, state: .waiting, text: CredentialsCopy.checkInstalled.filled(tool)),
                CheckLine(check: .signedIn, state: .waiting, text: CredentialsCopy.checkSignedIn.filled(tool)),
                CheckLine(check: .testPrompt, state: .waiting, text: CredentialsCopy.checkAnswers.filled(tool)),
            ]
        }
        signInNote = nil
        installAsk = nil
        isInstalling = false
        installFailure = nil
    }

    /// Sign in for a login: Add credential, then follow the helper's checks.
    /// Returns when the checks ended, failed, or were cancelled.
    func signIn() async {
        guard canStartChecks, !isToken, let provider else { return }
        let typed = trimmedName
        guard !typed.isEmpty else {
            nameLine = CredentialsCopy.nameRequired.text
            return
        }

        // The login uses the tool's default model and the agents' default rank (HE-5).
        let request = AddCredentialRequest(
            credentialID: credentialID, kind: .login, provider: provider, name: typed,
            model: ProviderNames.defaultModel(provider), strengthRank: 1)
        await startChecks(request)
    }

    func addToken() async {
        guard canAddToken, let provider else { return }
        guard !nameContainsToken else {
            name = ""
            nameLine = AddTokenCopy.nameContainsToken.text
            return
        }
        let request = AddCredentialRequest(
            credentialID: credentialID, kind: .apiToken, provider: provider, name: trimmedName,
            maskedLabel: MaskedLabel.forToken(token))
        await startChecks(request)
    }

    private func startChecks(_ request: AddCredentialRequest) async {
        isWorking = true
        failure = nil
        nameLine = nil
        resetChecks()
        step = .checking
        let task = Task { await self.runChecks(request) }
        checkTask = task
        await task.value
        checkTask = nil
        isWorking = false
    }

    private func runChecks(_ request: AddCredentialRequest) async {
        let provider = request.provider
        let isToken = request.kind == .apiToken
        let tokenCheck = isToken ? pendingTokenCheck : nil
        if isToken && tokenCheck == nil {
            do {
                try Task.checkCancellation()
                try await helper.send(.token(credentialID: credentialID, token: token))
            } catch is CancellationError {
                return
            } catch {
                if !Task.isCancelled { failure = AddTokenCopy.helperNotRunning.text }
                return
            }
        }

        do {
            try Task.checkCancellation()
            let requestID: UUID
            if let tokenCheck {
                // The server already accepted Add. Keep following its check.
                requestID = tokenCheck
            } else {
                let key = (addedRequest == request ? addKey : nil) ?? IdempotencyKey()
                addKey = key
                addedRequest = request
                let outcome = try await api.addCredential(request, key: key)
                guard let result = try outcome.completedResult() else { throw LeverageClientError.invalidBody }
                addKey = nil
                requestID = result.helperRequestID
                if isToken { pendingTokenCheck = requestID }
            }
            let follower = HelperRequestFollower(api: api, timing: timing)
            let end = try await follower.follow(requestID, giveUpAfter: timing.giveUpAfter) { [weak self] in
                if !Task.isCancelled { self?.apply($0) }
            }
            try Task.checkCancellation()
            let providerName = selection?.name ?? ProviderNames.name(provider)
            guard let end else {
                failure = isToken ? AddTokenCopy.failureLine(for: .timedOut, provider: providerName)
                    : CredentialsCopy.failTimedOut.filled(["tool": ProviderNames.tool(provider)])
                return
            }
            if isToken { pendingTokenCheck = nil }
            if end.succeeded {
                if isToken { discardTokenInput() }
                step = .done
                onAdded()
            } else {
                failure = isToken ? AddTokenCopy.failureLine(for: end.failedCheck?.failure, provider: providerName)
                    : CredentialsCopy.failureLine(for: end, provider: provider)
            }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            if CommandKey.wasAnswered(error) { addKey = nil }
            if case LeverageClientError.refused(let refusal) = error, refusal.code == .duplicateName {
                step = .nameIt
                nameLine = ShellCopy.refusalDuplicateName.text
            } else {
                failure = ShellCopy.sentence(for: error).text
            }
        }
    }

    func retry() async {
        if isToken { await addToken() } else { await signIn() }
    }

    /// Takes in what the helper has reported so far.
    private func apply(_ request: HelperRequest) {
        guard let provider else { return }
        checks = checks.map { line in
            guard let reported = request.progress.last(where: { $0.check == line.check }) else { return line }
            return CheckLine(check: line.check, state: reported.state, text: line.text)
        }
        guard !isToken else { return }
        let waitingForSignIn = request.progress.contains { $0.state == .waitingForSignIn }
        signInNote = waitingForSignIn
            ? (provider == .gemini ? CredentialsCopy.waitingGemini : CredentialsCopy.waitingSignIn).text : nil

        if let waiting = request.progress.last(where: { $0.state == .waitingForInstall }) {
            let tool = ProviderNames.tool(provider)
            if let offer = waiting.install, offer.installable {
                installAsk = InstallAsk(
                    text: CredentialsCopy.installAsk.filled([
                        "tool": tool, "what": offer.what ?? tool,
                        "source": offer.sourceURL?.absoluteString ?? "",
                    ]),
                    canInstall: true)
            } else {
                installAsk = InstallAsk(text: CredentialsCopy.installCant.filled(["tool": tool]), canInstall: false)
            }
        } else {
            installAsk = nil
            isInstalling = false
        }
    }

    // MARK: install

    /// Install, after the owner confirmed what and from where.
    func install() async {
        guard let provider, installAsk?.canInstall == true, !isInstalling else { return }
        installFailure = nil
        isInstalling = true
        let task = Task { await self.runInstall(provider: provider) }
        installTask = task
        await task.value
        installTask = nil
    }

    private func runInstall(provider: Provider) async {
        let key = installKey ?? IdempotencyKey()
        installKey = key
        do {
            let outcome = try await api.installTool(provider: provider, key: key)
            _ = try outcome.completedResult()
            installKey = nil
            if let requestID = outcome.helperRequestID {
                let follower = HelperRequestFollower(api: api, timing: timing)
                if let request = try await follower.follow(requestID, giveUpAfter: timing.giveUpAfter),
                   !request.succeeded {
                    isInstalling = false
                    installFailure = CredentialsCopy.installFailed.text
                }
            }
        } catch is CancellationError {
            return
        } catch {
            if CommandKey.wasAnswered(error) { installKey = nil }
            isInstalling = false
            installFailure = ShellCopy.sentence(for: error).text
        }
    }

    /// Cancel: stops following. The helper's own wait runs out by itself (CL-19).
    func cancel() {
        checkTask?.cancel()
        installTask?.cancel()
        discardTokenInput()
    }

    private func discardTokenInput() {
        if nameContainsToken { name = "" }
        token = ""
    }
}
