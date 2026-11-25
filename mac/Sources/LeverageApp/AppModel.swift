import Foundation
import LeverageKit
import Observation

/// The app's phases (plan §2.2): the server starting or missing, create the
/// sign-in, sign in, ready. It owns what the whole window shares once the
/// owner is signed in: the events tail, the health line and the way the
/// screens reach the server, and it keeps the helper running while the owner
/// is signed in (PK-4).
@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable, Sendable {
        /// Asking the server supervisor.
        case starting
        case dockerMissing
        case dockerStarting
        case dockerNotStarting
        case imageMissing
        case serverFailed
        /// The server was started but does not answer.
        case cannotReachServer
        case createSignIn
        case signIn
        case ready
    }

    private(set) var phase: Phase = .starting
    /// The sign-in screen's model, in the two sign-in phases.
    private(set) var signIn: SignInModel?
    /// What the screens share, once ready.
    private(set) var screens: ScreenContext?

    var isSignedIn: Bool { phase == .ready }

    @ObservationIgnored private let runtime: any AppRuntime
    @ObservationIgnored private let makeOwnerAPI: @Sendable (URL, String?) -> any OwnerAPI
    @ObservationIgnored private let pollInterval: Duration
    @ObservationIgnored private let log = Log(component: "app")
    @ObservationIgnored private var apiURL: URL?
    @ObservationIgnored private var rawOwner: (any OwnerAPI)?
    @ObservationIgnored private var activeSessionGeneration: UUID?
    @ObservationIgnored private var helperStart: Task<Void, Never>?
    @ObservationIgnored private var helperStop: Task<Void, Never>?
    @ObservationIgnored private var didLaunch = false
    @ObservationIgnored private var isQuitting = false

    /// `makeOwnerAPI` builds the owner's API for an address and a session
    /// token (nil before signing in); the app passes `OwnerClient`, tests a fake.
    init(
        runtime: any AppRuntime, makeOwnerAPI: @escaping @Sendable (URL, String?) -> any OwnerAPI,
        pollInterval: Duration = .milliseconds(500)
    ) {
        self.runtime = runtime
        self.makeOwnerAPI = makeOwnerAPI
        self.pollInterval = pollInterval
    }

    // MARK: launch

    /// Starts the app once; the window may appear again without starting it again.
    func launch() async {
        guard !didLaunch else { return }
        didLaunch = true
        await start()
    }

    /// Starts the server if it is not running, then finds out whether the
    /// owner has a session, has a sign-in to create, or has one to use.
    func start() async {
        guard phase != .ready else { return }
        phase = .starting
        let state = await startServer()
        switch state {
        case .running(let url): await openSession(at: url)
        case .dockerMissing: phase = .dockerMissing
        case .dockerStarting: phase = .dockerStarting
        case .dockerNotStarting: phase = .dockerNotStarting
        case .imageMissing: phase = .imageMissing
        case .notStarted, .starting, .failed: phase = .serverFailed
        }
    }

    /// The start-up screens' Check again and Try again.
    func checkAgain() async { await start() }

    /// Starts the server while showing what it is doing meanwhile.
    private func startServer() async -> ServerState {
        let server = runtime.server
        let watcher = Task { [weak self, pollInterval] in
            while !Task.isCancelled {
                let state = await server.state()
                self?.showMidway(state)
                try? await Task.sleep(for: pollInterval)
            }
        }
        let final = await server.start()
        watcher.cancel()
        await watcher.value
        return final
    }

    private func showMidway(_ state: ServerState) {
        guard phase != .ready, signIn == nil else { return }
        switch state {
        case .dockerMissing: phase = .dockerMissing
        case .dockerStarting: phase = .dockerStarting
        case .dockerNotStarting: phase = .dockerNotStarting
        case .imageMissing: phase = .imageMissing
        case .starting: phase = .starting
        case .notStarted, .running, .failed: break
        }
    }

    // MARK: the session

    private func openSession(at url: URL) async {
        apiURL = url
        // A session that cannot be read is no session (MA-7).
        let kept = try? runtime.sessions.load()
        if let kept {
            let signedIn = makeOwnerAPI(url, kept)
            do {
                _ = try await signedIn.systemHealth()
                enterReady(url: url, token: kept)
                return
            } catch let error as TransportError where error.code == .unauthenticated {
                try? runtime.sessions.clear()
            } catch {
                phase = .cannotReachServer
                return
            }
        }
        let api = makeOwnerAPI(url, nil)
        do {
            let setup = try await api.setupState()
            beginSignIn(mode: setup.ownerExists ? .signIn : .create, api: api, url: url)
        } catch {
            phase = .cannotReachServer
        }
    }

    private func beginSignIn(mode: SignInModel.Mode, api: any OwnerAPI, url: URL) {
        signIn = SignInModel(mode: mode, api: api) { [weak self] token in
            self?.signedIn(token: token, at: url)
        }
        phase = mode == .create ? .createSignIn : .signIn
    }

    private func signedIn(token: String, at url: URL) {
        do {
            try runtime.sessions.save(token)
        } catch {
            // The session works until the app closes; the next launch asks again.
            log.warning("the session could not be kept: \(error.localizedDescription)")
        }
        enterReady(url: url, token: token)
    }

    private func enterReady(url: URL, token: String) {
        let raw = makeOwnerAPI(url, token)
        let generation = UUID()
        let guarded = SessionGuard(base: raw) { [weak self] in
            self?.sessionEnded(generation: generation)
        }
        let feed = EventFeed(owner: guarded)
        let health = HealthLineModel(owner: guarded, helper: runtime.helper, server: runtime.server)
        rawOwner = raw
        activeSessionGeneration = generation
        screens = ScreenContext(owner: guarded, feed: feed, health: health, runtime: runtime)
        signIn = nil
        phase = .ready
        // The helper starts after the owner signs in, and never blocks the window (PK-4).
        guard !isQuitting else { return }
        let stopping = helperStop
        helperStop = nil
        let runtime = runtime
        helperStart = Task {
            await stopping?.value
            _ = await runtime.helper.start(apiBaseURL: url, issuer: OwnerHelperTokenIssuer(owner: guarded))
        }
    }

    /// Sign out in the app menu (MA-6): ends the session on the server when
    /// it can be reached, and here either way.
    func signOut() async {
        guard phase == .ready, let raw = rawOwner, let generation = activeSessionGeneration else { return }
        _ = try? await raw.signOut(key: IdempotencyKey())
        sessionEnded(generation: generation)
    }

    /// The session is over, by Sign out or by a 401 from any call: forget it,
    /// stop what ran for it and show Sign in. Does nothing twice.
    private func sessionEnded(generation: UUID) {
        guard phase == .ready, activeSessionGeneration == generation, let url = apiURL else { return }
        activeSessionGeneration = nil
        screens?.feed.stop()
        screens = nil
        rawOwner = nil
        try? runtime.sessions.clear()
        stopHelper()
        beginSignIn(mode: .signIn, api: makeOwnerAPI(url, nil), url: url)
    }

    /// A replacement session waits for this stop, as does a concurrent quit.
    @discardableResult
    private func stopHelper() -> Task<Void, Never> {
        if let helperStop { return helperStop }
        let starting = helperStart
        helperStart = nil
        let runtime = runtime
        let stopping = Task {
            await starting?.value
            await runtime.helper.stop()
        }
        helperStop = stopping
        return stopping
    }

    // MARK: quitting

    /// Before the app quits: the events tail ends and the helper is asked to
    /// stop, which stops the runs (PK-8). The owner stays signed in.
    func prepareToQuit() async {
        isQuitting = true
        screens?.feed.stop()
        await stopHelper().value
    }
}
