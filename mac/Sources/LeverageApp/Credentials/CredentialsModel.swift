import Foundation
import LeverageKit
import Observation

/// One login on the Credentials list: its name, its kind, its provider, a
/// chip for its state and a sentence for what it can do (MA-8).
struct CredentialRow: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    let kindLine: String
    let providerName: String
    let provider: Provider
    let chip: CardChip
    let usage: String
    /// A signed-out login can be signed in again (HM-47).
    let canSignInAgain: Bool

    enum Action { case rename, verify, signInAgain, remove }
    let actions: [Action] = []
    let isSignedOut = false
    let accountDetails: [String] = []
    let figures: [FigureTile.Content] = []
    let resetsLine: String? = nil
    let ageLine: String? = nil
    let readingLine: String? = nil
    let modelLine: String? = nil
    let tokenLine: String? = nil

    init(
        _ entry: CredentialWithReading, now: Date, calendar: Calendar = .current, locale: Locale = .current,
        testedVersions: [String]? = nil
    ) {
        let credential = entry.credential
        id = credential.id
        name = credential.name
        provider = credential.provider
        providerName = ProviderNames.name(credential.provider)
        kindLine = (credential.kind == .login ? CredentialsCopy.kindLogin : .kindToken).text
        canSignInAgain = credential.kind == .login && credential.state == .signedOut
        if credential.state == .signedOut {
            chip = CardChip(text: CredentialsCopy.chipSignedOut.text, tone: .stop)
            usage = CredentialsCopy.usageSignedOut.text
        } else if credential.isLimited(at: now) {
            chip = CardChip(text: CredentialsCopy.chipLimit.text, tone: .stop)
            if let until = credential.limitedUntil {
                let clock = ResetClock(now: { now }, calendar: calendar, locale: locale)
                usage = CredentialsCopy.usageLimitUntil.filled(["time": ResetTime.text(for: until, clock: clock)])
            } else {
                usage = CredentialsCopy.usageLimitNoTime.filled(["provider": ProviderNames.name(credential.provider)])
            }
        } else {
            chip = CardChip(text: CredentialsCopy.chipReady.text, tone: .info)
            usage = CredentialsCopy.usageReady.text
        }
    }
}

/// The Credentials list: the logins from `list_credentials`, and Verify for
/// each (MA-8). It reads again whenever the events tail delivers a batch; a
/// read that fails keeps the rows already shown.
@MainActor
@Observable
final class CredentialsModel {
    enum State: Equatable, Sendable {
        case loading
        case loaded
        case failed(ShellCopy)
        /// The sign-in ended. The shell returns the app to Sign in.
        case signedOut
    }

    struct Group {
        let provider: Provider
        let rows: [CredentialRow]
    }

    struct Section {
        let kind: CredentialKind
        let groups: [Group]
    }

    var sections: [Section] { [] }
    var pendingRemoval: CredentialRow? { nil }
    func askToRemove(_ id: UUID) {}
    func cancelRemoval() {}
    func remove(_ id: UUID) async {}
    func rename(_ id: UUID, to name: String) async -> String? { nil }
    func refresh() async {}
    func verifyAll() async {}
    func progress(for id: UUID) -> String? { nil }
    func keepCurrent(every interval: Duration = .seconds(10)) async { await load() }

    private(set) var state: State = .loading
    private(set) var rows: [CredentialRow] = []
    private(set) var verifying: Set<UUID> = []
    private(set) var signingIn: Set<UUID> = []
    private(set) var failures: [UUID: String] = [:]

    @ObservationIgnored private let api: any OwnerAPI
    @ObservationIgnored private let noteRead: @MainActor (Int) -> Void
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let timing: FollowTiming
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private let locale: Locale
    @ObservationIgnored private var verifyKeys: [UUID: IdempotencyKey] = [:]
    @ObservationIgnored private var signInKeys: [UUID: IdempotencyKey] = [:]
    @ObservationIgnored private var subscription: EventFeed.Subscription?
    @ObservationIgnored private var generation = 0

    init(
        api: any OwnerAPI, noteRead: @escaping @MainActor (Int) -> Void, now: @escaping () -> Date = Date.init,
        timing: FollowTiming = .normal, calendar: Calendar = .current, locale: Locale = .current,
        helper: (any HelperSupervising)? = nil
    ) {
        self.api = api
        self.noteRead = noteRead
        self.now = now
        self.timing = timing
        self.calendar = calendar
        self.locale = locale
    }

    func isVerifying(_ id: UUID) -> Bool { verifying.contains(id) }

    /// Sign in again is running for that login: the helper opened the
    /// provider's sign-in, and the app waits for the owner (MA-17).
    func isSigningIn(_ id: UUID) -> Bool { signingIn.contains(id) }
    /// The line a row shows while Sign in again waits for the owner, or nil:
    /// Antigravity has no sign-in command, so no window opens for Gemini.
    func signInWaitingLine(_ id: UUID) -> String? {
        guard signingIn.contains(id) else { return nil }
        let gemini = rows.first(where: { $0.id == id })?.provider == .gemini
        return (gemini ? CredentialsCopy.waitingGemini : .waitingSignIn).text
    }

    /// The line a failed Verify left on that row.
    func failure(for id: UUID) -> String? { failures[id] }

    /// Reads the list.
    func load() async {
        generation += 1
        let mine = generation
        do {
            let list = try await api.credentials()
            guard mine == generation else { return }
            let at = now()
            rows = list.credentials.map { CredentialRow($0, now: at, calendar: calendar, locale: locale) }
            state = .loaded
            noteRead(list.asOfSeq)
        } catch is CancellationError {
            return
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch let error as TransportError where error.code == .unauthenticated {
            if mine == generation { state = .signedOut }
        } catch {
            if mine == generation { state = .failed(ShellCopy.sentence(for: error)) }
        }
    }

    /// Verify: asks the helper to run the checks again, follows the request,
    /// and reads the list again. A repeat after the network failed sends the
    /// same command (the key is kept until the server has answered).
    func verify(_ id: UUID) async {
        guard let row = rows.first(where: { $0.id == id }), !verifying.contains(id) else { return }
        verifying.insert(id)
        failures[id] = nil
        defer { verifying.remove(id) }
        let key = verifyKeys[id] ?? IdempotencyKey()
        verifyKeys[id] = key
        do {
            let outcome = try await api.verifyCredential(credentialID: id, key: key)
            _ = try outcome.completedResult()
            verifyKeys[id] = nil
            if let requestID = outcome.helperRequestID {
                let follower = HelperRequestFollower(api: api, timing: timing)
                if let request = try await follower.follow(requestID, giveUpAfter: timing.giveUpAfter),
                   !request.succeeded {
                    failures[id] = CredentialsCopy.failureLine(for: request, provider: row.provider)
                }
            }
            await load()
        } catch is CancellationError {
            return
        } catch {
            if CommandKey.wasAnswered(error) { verifyKeys[id] = nil }
            failures[id] = ShellCopy.sentence(for: error).text
        }
    }

    /// Sign in again, on a signed-out login: asks the helper to open the
    /// provider's sign-in, follows the request to its end, and reads again
    /// (HM-47, HE-36). The key is kept until the server has answered.
    func signInAgain(_ id: UUID) async {
        guard let row = rows.first(where: { $0.id == id }), row.canSignInAgain, !signingIn.contains(id) else { return }
        signingIn.insert(id)
        failures[id] = nil
        defer { signingIn.remove(id) }
        let key = signInKeys[id] ?? IdempotencyKey()
        signInKeys[id] = key
        do {
            let outcome = try await api.signInAgain(credentialID: id, key: key)
            _ = try outcome.completedResult()
            signInKeys[id] = nil
            if let requestID = outcome.helperRequestID {
                let follower = HelperRequestFollower(api: api, timing: timing)
                if let request = try await follower.follow(requestID, giveUpAfter: timing.giveUpAfter),
                   !request.succeeded {
                    failures[id] = CredentialsCopy.failureLine(for: request, provider: row.provider)
                }
            }
            signingIn.remove(id)
            await load()
        } catch is CancellationError {
            return
        } catch {
            if CommandKey.wasAnswered(error) { signInKeys[id] = nil }
            failures[id] = ShellCopy.sentence(for: error).text
        }
    }

    /// Reads again each time the events tail delivers a batch.
    func attach(to feed: EventFeed) {
        subscription?.cancel()
        subscription = feed.subscribe { [weak self] _ in
            Task { await self?.load() }
        }
    }

    func detach() {
        subscription?.cancel()
        subscription = nil
    }
}
