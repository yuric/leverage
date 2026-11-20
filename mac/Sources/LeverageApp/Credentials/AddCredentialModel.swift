import Foundation
import LeverageKit
import Observation

/// The Add credential pop-up (MA-17, SC-5, MA-26, MA-27, IN-23, IN-24): step 1
/// picks a provider, step 2 names the login and starts the checks, and the
/// checks tick off as the helper reports them. A failed check stays in the
/// pop-up with one line and a Retry; a missing tool shows what would be
/// installed and from where, and waits for the owner's say (PV-5).
///
/// Add is sent once per try. Retry sends it again with a new key and the same
/// credential id (IN-24); pressing Sign in again after the network failed
/// sends the same command under the same key.
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
    private(set) var provider: Provider?
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
    @ObservationIgnored let credentialID: UUID
    @ObservationIgnored private let onAdded: @MainActor () -> Void
    @ObservationIgnored private let timing: FollowTiming
    @ObservationIgnored private var added: Set<Provider> = []
    @ObservationIgnored private var addKey: IdempotencyKey?
    @ObservationIgnored private var addedRequest: AddCredentialRequest?
    @ObservationIgnored private var installKey: IdempotencyKey?
    @ObservationIgnored private var signInTask: Task<Void, Never>?
    @ObservationIgnored private var installTask: Task<Void, Never>?

    /// Only these have one sign-in for the Mac (CL-20, CL-21).
    private static let oneForTheMac: Set<Provider> = [.gemini, .grok]

    init(
        api: any OwnerAPI, credentialID: UUID = UUID(), onAdded: @escaping @MainActor () -> Void,
        timing: FollowTiming = .normal
    ) {
        self.api = api
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
                provider: $0, name: ProviderNames.name($0), isAdded: Self.oneForTheMac.contains($0) && added.contains($0))
        }
    }

    func pick(_ choice: Provider) {
        guard step == .pickProvider, providers.first(where: { $0.provider == choice })?.isAdded == false else { return }
        provider = choice
        failure = nil
        resetChecks()
        step = .nameIt
    }

    func back() {
        guard step == .nameIt, !isWorking else { return }
        step = .pickProvider
    }

    // MARK: step 2 and the checks

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Whether Sign in (or Retry) can be pressed.
    var canSignIn: Bool {
        provider != nil && !trimmedName.isEmpty && !isWorking && (step == .nameIt || canRetry)
    }

    /// A failed try is showing, and nothing is running.
    var canRetry: Bool { step == .checking && failure != nil && !isWorking }

    var installNote: String? {
        guard isInstalling, let provider else { return nil }
        return CredentialsCopy.installing.filled(["tool": ProviderNames.tool(provider)])
    }

    private func resetChecks() {
        guard let provider else { checks = []; return }
        let tool = ["tool": ProviderNames.tool(provider)]
        checks = [
            CheckLine(check: .toolInstalled, state: .waiting, text: CredentialsCopy.checkInstalled.filled(tool)),
            CheckLine(check: .signedIn, state: .waiting, text: CredentialsCopy.checkSignedIn.filled(tool)),
            CheckLine(check: .testPrompt, state: .waiting, text: CredentialsCopy.checkAnswers.filled(tool)),
        ]
        signInNote = nil
        installAsk = nil
        isInstalling = false
        installFailure = nil
    }

    /// Sign in for a login: Add credential, then follow the helper's checks.
    /// Returns when the checks ended, failed, or were cancelled.
    func signIn() async {
        guard step == .nameIt || canRetry, !isWorking, let provider else { return }
        let typed = trimmedName
        guard !typed.isEmpty else {
            nameLine = CredentialsCopy.nameRequired.text
            return
        }
        isWorking = true
        failure = nil
        resetChecks()
        step = .checking
        let task = Task { await self.runChecks(provider: provider, name: typed) }
        signInTask = task
        await task.value
        signInTask = nil
        isWorking = false
    }

    private func runChecks(provider: Provider, name typed: String) async {

        // The model is the one the provider's tool names as its default, where it names one (Claude, Grok);
        // the rank is the agents' default, and the effort stays empty (HE-5).
        let request = AddCredentialRequest(
            credentialID: credentialID, kind: .login, provider: provider, name: typed,
            model: ProviderNames.defaultModel(provider), strengthRank: 1)
        let key = (addedRequest == request ? addKey : nil) ?? IdempotencyKey()
        addKey = key
        addedRequest = request
        do {
            let outcome = try await api.addCredential(request, key: key)
            guard let result = try outcome.completedResult() else { throw LeverageClientError.invalidBody }
            addKey = nil
            let follower = HelperRequestFollower(api: api, timing: timing)
            let end = try await follower.follow(result.helperRequestID, giveUpAfter: timing.giveUpAfter) { [weak self] in
                self?.apply($0)
            }
            guard let end else {
                failure = CredentialsCopy.failTimedOut.filled(["tool": ProviderNames.tool(provider)])
                return
            }
            if end.succeeded {
                step = .done
                onAdded()
            } else {
                failure = CredentialsCopy.failureLine(for: end, provider: provider)
            }
        } catch is CancellationError {
            return
        } catch {
            if CommandKey.wasAnswered(error) { addKey = nil }
            if case LeverageClientError.refused(let refusal) = error, refusal.code == .duplicateName {
                step = .nameIt
                nameLine = ShellCopy.refusalDuplicateName.text
            } else {
                failure = ShellCopy.sentence(for: error).text
            }
        }
    }

    func retry() async { await signIn() }

    /// Takes in what the helper has reported so far.
    private func apply(_ request: HelperRequest) {
        guard let provider else { return }
        checks = checks.map { line in
            guard let reported = request.progress.last(where: { $0.check == line.check }) else { return line }
            return CheckLine(check: line.check, state: reported.state, text: line.text)
        }
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
        signInTask?.cancel()
        installTask?.cancel()
    }
}
