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

    init(_ entry: CredentialWithReading, now: Date, calendar: Calendar = .current, locale: Locale = .current) {
        let credential = entry.credential
        id = credential.id
        name = credential.name
        provider = credential.provider
        providerName = ProviderNames.name(credential.provider)
        kindLine = (credential.kind == .login ? CredentialsCopy.kindLogin : .kindToken).text
        canSignInAgain = false
        if credential.state == .signedOut {
            chip = CardChip(text: CredentialsCopy.chipSignedOut.text, tone: .stop)
            usage = CredentialsCopy.usageSignedOut.text
        } else if let until = credential.limitedUntil, until > now {
            chip = CardChip(text: CredentialsCopy.chipLimit.text, tone: .stop)
            usage = CredentialsCopy.usageUntil.filled(["time": until.formatted(date: .abbreviated, time: .shortened)])
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

    private(set) var state: State = .loading
    private(set) var rows: [CredentialRow] = []
    private(set) var verifying: Set<UUID> = []
    private(set) var failures: [UUID: String] = [:]

    @ObservationIgnored private let api: any OwnerAPI
    @ObservationIgnored private let noteRead: @MainActor (Int) -> Void
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let timing: FollowTiming
    @ObservationIgnored private var verifyKeys: [UUID: IdempotencyKey] = [:]
    @ObservationIgnored private var subscription: EventFeed.Subscription?
    @ObservationIgnored private var generation = 0

    init(
        api: any OwnerAPI, noteRead: @escaping @MainActor (Int) -> Void, now: @escaping () -> Date = Date.init,
        timing: FollowTiming = .normal, calendar: Calendar = .current, locale: Locale = .current
    ) {
        self.api = api
        self.noteRead = noteRead
        self.now = now
        self.timing = timing
    }

    func isVerifying(_ id: UUID) -> Bool { verifying.contains(id) }

    func isSigningIn(_ id: UUID) -> Bool { false }

    func signInAgain(_ id: UUID) async {}

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
            rows = list.credentials.map { CredentialRow($0, now: at) }
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
