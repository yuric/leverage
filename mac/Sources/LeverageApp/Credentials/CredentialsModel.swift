import Foundation
import LeverageKit
import Observation

/// The Credentials list and its owner commands. Reads that fail keep the last rows.
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

    private enum Batch: Hashable, Sendable {
        case refresh, verify

        var progress: CredentialsCopy { self == .refresh ? .readingUsage : .verifying }
    }

    var sections: [Section] {
        CredentialKind.allCases.map { kind in
            let byProvider = Dictionary(grouping: rows.filter { $0.kind == kind }, by: \.provider)
            let groups = Provider.allCases.compactMap { provider in
                byProvider[provider].map { Group(provider: provider, rows: $0) }
            }
            return Section(kind: kind, groups: groups)
        }
    }

    var isRunningBatch: Bool { batch != nil }
    var canVerifyAll: Bool { batch == nil && verifying.isEmpty && signingIn.isEmpty }

    private(set) var state: State = .loading
    private(set) var rows: [CredentialRow] = []
    private(set) var verifying: Set<UUID> = []
    private(set) var signingIn: Set<UUID> = []
    private var failures: [UUID: String] = [:]
    private var refreshFailures: [UUID: (at: Date, line: String)] = [:]
    private(set) var pendingRemoval: CredentialRow?
    private(set) var actionFailure: String?
    private var batch: Batch?
    private var batchRows: [UUID: UUID] = [:]
    private var renaming: Set<UUID> = []
    private var removing: Set<UUID> = []

    @ObservationIgnored private let api: any OwnerAPI
    @ObservationIgnored private let helper: any HelperSupervising
    @ObservationIgnored private let noteRead: @MainActor (Int) -> Void
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let timing: FollowTiming
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private let locale: Locale
    @ObservationIgnored private var verifyKeys: [UUID: IdempotencyKey] = [:]
    @ObservationIgnored private var signInKeys: [UUID: IdempotencyKey] = [:]
    @ObservationIgnored private var renameKeys: [UUID: (name: String, key: IdempotencyKey)] = [:]
    @ObservationIgnored private var removeKeys: [UUID: IdempotencyKey] = [:]
    @ObservationIgnored private var batchKeys: [Batch: IdempotencyKey] = [:]
    @ObservationIgnored private var subscription: EventFeed.Subscription?
    @ObservationIgnored private var generation = 0

    init(
        api: any OwnerAPI, noteRead: @escaping @MainActor (Int) -> Void, now: @escaping () -> Date = Date.init,
        timing: FollowTiming = .normal, calendar: Calendar = .current, locale: Locale = .current,
        helper: any HelperSupervising
    ) {
        self.api = api
        self.helper = helper
        self.noteRead = noteRead
        self.now = now
        self.timing = timing
        self.calendar = calendar
        self.locale = locale
    }

    func isVerifying(_ id: UUID) -> Bool { verifying.contains(id) }

    func canVerify(_ id: UUID) -> Bool {
        batch != .verify && !isVerifying(id) && !isSigningIn(id) && !removing.contains(id)
    }

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

    func failure(for id: UUID) -> String? { failures[id] ?? refreshFailures[id]?.line }

    func progress(for id: UUID) -> String? {
        if removing.contains(id) { return CredentialsCopy.removing.text }
        if renaming.contains(id) { return CredentialsCopy.renaming.text }
        if verifying.contains(id) { return CredentialsCopy.verifying.text }
        if let waiting = signInWaitingLine(id) { return waiting }
        return batchRows.values.contains(id) ? batch?.progress.text : nil
    }

    /// Reads now and every ten seconds while the tab's task is running.
    func keepCurrent(every interval: Duration = .seconds(10)) async {
        while !Task.isCancelled {
            await load()
            do { try await Task.sleep(for: interval) } catch { return }
        }
    }

    /// Reads the list.
    func load() async {
        generation += 1
        let mine = generation
        do {
            let list = try await api.credentials()
            guard mine == generation, !Task.isCancelled else { return }
            let at = now()
            rows = list.credentials.map { CredentialRow($0, now: at, calendar: calendar, locale: locale) }
            for entry in list.credentials {
                let id = entry.credential.id
                if let failure = refreshFailures[id], let reading = entry.reading,
                   reading.state == .ok, reading.observedAt > failure.at {
                    refreshFailures[id] = nil
                }
            }
            state = .loaded
            noteRead(list.asOfSeq)
            await recoverRemovals()
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

    func rename(_ id: UUID, to draft: String) async -> String? {
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return CredentialsCopy.nameRequired.text }
        guard rows.contains(where: { $0.id == id }), !removing.contains(id) else {
            return ShellCopy.transportNotFound.text
        }
        guard renaming.insert(id).inserted else { return CredentialsCopy.renaming.text }
        defer { renaming.remove(id) }
        let key: IdempotencyKey
        if let previous = renameKeys[id], previous.name == name {
            key = previous.key
        } else {
            key = IdempotencyKey()
        }
        renameKeys[id] = (name, key)
        do {
            let outcome = try await api.renameCredential(credentialID: id, RenameCredentialRequest(name: name), key: key)
            _ = try outcome.completedResult()
            renameKeys[id] = nil
            await load()
            return nil
        } catch is CancellationError {
            return ShellCopy.somethingWentWrong.text
        } catch {
            if CommandKey.wasAnswered(error) { renameKeys[id] = nil }
            return ShellCopy.sentence(for: error).text
        }
    }

    func askToRemove(_ id: UUID) {
        pendingRemoval = rows.first { $0.id == id }
    }

    func cancelRemoval() { pendingRemoval = nil }

    /// The destructive action of the confirmation dialog.
    func remove(_ id: UUID) async {
        pendingRemoval = nil
        guard let row = rows.first(where: { $0.id == id }), !renaming.contains(id),
              removing.insert(id).inserted else { return }
        defer { removing.remove(id) }
        failures[id] = nil
        actionFailure = nil
        let key = removeKeys[id] ?? IdempotencyKey()
        removeKeys[id] = key
        do {
            let outcome = try await api.removeCredential(credentialID: id, key: key)
            _ = try outcome.completedResult()
        } catch is CancellationError {
            return
        } catch {
            if CommandKey.wasAnswered(error) { removeKeys[id] = nil }
            if case LeverageClientError.refused(let refusal) = error, refusal.code == .credentialInUse {
                failures[id] = CredentialsCopy.inUse.filled(["name": row.name])
            } else {
                failures[id] = ShellCopy.sentence(for: error).text
            }
            return
        }
        await finishRemoval(id)
        await load()
    }

    /// Resolve a lost Remove response after the list shows the row is gone.
    /// The owner's command record confirms that this app should send forget.
    private func recoverRemovals() async {
        let visible = Set(rows.map(\.id))
        for (id, key) in removeKeys where !visible.contains(id) && removing.insert(id).inserted {
            defer { removing.remove(id) }
            do {
                let outcome = try await api.command(key: key)
                _ = try outcome.completedResult()
                await finishRemoval(id)
            } catch is CancellationError {
                return
            } catch {
                if CommandKey.wasAnswered(error) { removeKeys[id] = nil }
            }
        }
    }

    private func finishRemoval(_ id: UUID) async {
        removeKeys[id] = nil
        renameKeys[id] = nil
        failures[id] = nil
        refreshFailures[id] = nil
        // A read already underway may have seen the row just before removal.
        generation += 1
        rows.removeAll { $0.id == id }
        do {
            try await helper.send(.forget(credentialID: id))
        } catch {
            actionFailure = CredentialsCopy.cleanupFailed.text
        }
    }

    func refresh() async { await runBatch(.refresh) }

    func verifyAll() async { await runBatch(.verify) }

    private func runBatch(_ action: Batch) async {
        guard action == .verify ? canVerifyAll : !isRunningBatch else { return }
        batch = action
        actionFailure = nil
        defer { batch = nil }
        let key = batchKeys[action] ?? IdempotencyKey()
        batchKeys[action] = key
        do {
            let outcome = switch action {
            case .refresh: try await api.refreshUsage(key: key)
            case .verify: try await api.verifyAllCredentials(key: key)
            }
            guard let queued = try outcome.completedResult() else { throw LeverageClientError.invalidBody }
            batchKeys[action] = nil
            if queued.helperRequestIDs.isEmpty { await load() }
            await withTaskGroup(of: Void.self) { group in
                for id in queued.helperRequestIDs {
                    group.addTask { await self.followBatchRequest(id, action: action) }
                }
            }
        } catch is CancellationError {
            return
        } catch {
            if CommandKey.wasAnswered(error) { batchKeys[action] = nil }
            actionFailure = ShellCopy.sentence(for: error).text
        }
    }

    private func followBatchRequest(_ requestID: UUID, action: Batch) async {
        var credentialID: UUID?
        let follower = HelperRequestFollower(api: api, timing: timing)
        let failure: String?
        do {
            let request = try await follower.follow(
                requestID, giveUpAfter: action == .refresh ? timing.quickGiveUpAfter : timing.giveUpAfter
            ) { request in
                guard credentialID == nil, let id = request.credentialID else { return }
                credentialID = id
                batchRows[requestID] = id
                if action == .refresh { refreshFailures[id] = nil } else { failures[id] = nil }
            }
            if let request, request.succeeded {
                failure = nil
            } else if action == .refresh {
                failure = CredentialsCopy.unavailable.text
            } else if let request, let row = rows.first(where: { $0.id == credentialID }) {
                failure = verificationFailure(request, row: row)
            } else {
                failure = CredentialsCopy.failedGeneric.text
            }
        } catch is CancellationError {
            batchRows[requestID] = nil
            return
        } catch {
            failure = ShellCopy.sentence(for: error).text
        }

        batchRows[requestID] = nil
        guard !Task.isCancelled else { return }
        if let failure {
            if let id = credentialID {
                if rows.contains(where: { $0.id == id }) {
                    if action == .refresh {
                        refreshFailures[id] = (now(), failure)
                    } else {
                        failures[id] = failure
                    }
                }
            } else {
                actionFailure = failure
            }
        }
        await load()
    }

    private func verificationFailure(_ request: HelperRequest, row: CredentialRow) -> String {
        guard row.kind == .apiToken else { return CredentialsCopy.failureLine(for: request, provider: row.provider) }
        let failure = request.failedCheck?.failure
        if failure == .rejected || failure == .notSignedIn { return CredentialsCopy.tokenStopped.text }
        return AddTokenCopy.failureLine(for: failure, provider: row.providerName)
    }

    /// Verify: asks the helper to run the checks again, follows the request,
    /// and reads the list again. A repeat after the network failed sends the
    /// same command (the key is kept until the server has answered).
    func verify(_ id: UUID) async {
        guard let row = rows.first(where: { $0.id == id }), canVerify(id) else { return }
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
                    failures[id] = verificationFailure(request, row: row)
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
        guard let row = rows.first(where: { $0.id == id }), row.canSignInAgain, canVerify(id) else { return }
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
