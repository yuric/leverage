import AppKit
import Foundation
import LeverageKit
import LeverageTestSupport
import Testing

@testable import LeverageApp

/// A server supervisor whose `start()` is still working until the test
/// lets it finish, so the screens in between can be seen.
private final class SlowServer: ServerSupervising, @unchecked Sendable {
    let midway = Locked(ServerState.dockerStarting)
    let finish = Locked<ServerState?>(nil)

    func state() async -> ServerState { finish.value ?? midway.value }

    func start() async -> ServerState {
        while true {
            if let done = finish.value { return done }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }
}

/// A helper supervisor that keeps the issuer it was started with.
private final class RecordingHelper: HelperSupervising, @unchecked Sendable {
    let issuer = Locked<(any HelperTokenIssuing)?>(nil)

    func state() async -> HelperState { .running }

    func start(apiBaseURL: URL, issuer: any HelperTokenIssuing) async -> HelperState {
        self.issuer.value = issuer
        return .running
    }

    func tryAgain() async -> HelperState { .running }
    func stop() async {}
}

private struct RecordingRuntime: AppRuntime {
    let server: any ServerSupervising = FakeAppRuntime().fakeServer
    let helper: any HelperSupervising
    let sessions: any SessionStoring
}

private struct SlowRuntime: AppRuntime {
    let server: any ServerSupervising
    let helper: any HelperSupervising = FakeAppRuntime().fakeHelper
    let sessions: any SessionStoring = FakeAppRuntime().fakeSessions
}

@MainActor
@Suite("AppModel: launch")
struct AppModelLaunchTests {
    @Test("a new installation, with the server running, shows Create your sign-in")
    func newInstallation() async {
        let rig = ShellRig()
        rig.scriptSignIn(ownerExists: false)
        let model = rig.makeModel()

        await model.start()

        #expect(model.phase == .createSignIn)
        #expect(model.signIn?.mode == .create)
        #expect(model.screens == nil)
        #expect(!model.isSignedIn)
        #expect(rig.runtime.fakeServer.startCount.value == 1)
        #expect(rig.factoryCalls.value == [FactoryCall(url: ShellFixtures.apiURL, token: nil)])
        #expect(rig.runtime.fakeHelper.starts.value.isEmpty)
    }

    @Test("launch starts the app once, however often the window appears")
    func launchOnce() async {
        let rig = ShellRig()
        rig.scriptSignIn(ownerExists: true)
        let model = rig.makeModel()

        await model.launch()
        await model.launch()

        #expect(rig.runtime.fakeServer.startCount.value == 1)
        #expect(model.phase == .signIn)
    }

    @Test("an installation that has an owner shows Sign in")
    func existingOwner() async {
        let rig = ShellRig()
        rig.scriptSignIn(ownerExists: true)
        let model = rig.makeModel()

        await model.start()

        #expect(model.phase == .signIn)
        #expect(model.signIn?.mode == .signIn)
    }

    @Test("a kept session that the server still accepts goes straight to the app, and the helper starts")
    func keptSession() async {
        let rig = ShellRig()
        rig.scriptSignIn(ownerExists: true)
        rig.runtime.fakeSessions.token.value = "stored-made-up-token"
        let model = rig.makeModel()

        await model.start()

        #expect(model.phase == .ready)
        #expect(model.isSignedIn)
        #expect(model.signIn == nil)
        #expect(model.screens != nil)
        #expect(rig.factoryCalls.value.contains(FactoryCall(url: ShellFixtures.apiURL, token: "stored-made-up-token")))
        #expect(await ShellFixtures.eventually { rig.runtime.fakeHelper.starts.value == [ShellFixtures.apiURL] })
        // The setup read is not needed when the session works.
        #expect(!rig.owner.calls.map(\.operation).contains(.getSetupState))
    }

    @Test("a kept session the server refuses is forgotten, and Sign in shows (MA-6)")
    func keptSessionRefused() async {
        let rig = ShellRig()
        rig.scriptSignIn(ownerExists: true)
        rig.owner.script { $0.systemHealth = { throw ShellFixtures.unauthenticated() } }
        rig.runtime.fakeSessions.token.value = "stored-made-up-token"
        let model = rig.makeModel()

        await model.start()

        #expect(model.phase == .signIn)
        #expect(rig.runtime.fakeSessions.token.value == nil)
        #expect(rig.runtime.fakeHelper.starts.value.isEmpty)
    }

    @Test("a kept session is not forgotten just because the server cannot be reached")
    func keptSessionUnreachable() async {
        let rig = ShellRig()
        rig.owner.script { $0.systemHealth = { throw URLError(.cannotConnectToHost) } }
        rig.runtime.fakeSessions.token.value = "stored-made-up-token"
        let model = rig.makeModel()

        await model.start()

        #expect(model.phase == .cannotReachServer)
        #expect(rig.runtime.fakeSessions.token.value == "stored-made-up-token")
    }

    @Test("when the setup read cannot reach the server, the app says so instead of showing a form")
    func setupUnreachable() async {
        let rig = ShellRig()
        rig.owner.script { $0.setupState = { throw URLError(.timedOut) } }
        let model = rig.makeModel()

        await model.start()

        #expect(model.phase == .cannotReachServer)
    }

    @Test("Check again after the server could not be reached asks the server to start again, and goes on when it answers")
    func checkAgainRestartsServer() async {
        let rig = ShellRig()
        let answering = Locked(false)
        rig.owner.script {
            $0.setupState = {
                if answering.value { return SetupState(ownerExists: true) }
                throw URLError(.cannotConnectToHost)
            }
        }
        let model = rig.makeModel()
        await model.start()
        #expect(model.phase == .cannotReachServer)

        answering.value = true
        await model.checkAgain()

        #expect(rig.runtime.fakeServer.startCount.value == 2)
        #expect(model.phase == .signIn)
    }


    @Test("a session store that cannot be read means Sign in, not a stop (MA-7)")
    func storeUnreadable() async {
        let rig = ShellRig()
        rig.scriptSignIn(ownerExists: true)
        rig.runtime.fakeSessions.failure.value = URLError(.cannotOpenFile)
        let model = rig.makeModel()

        await model.start()

        #expect(model.phase == .signIn)
    }

    @Test("each state the server can end in has its own screen")
    func serverStates() async {
        let table: [(ServerState, AppModel.Phase)] = [
            (.dockerMissing, .dockerMissing),
            (.dockerStarting, .dockerStarting),
            (.dockerNotStarting, .dockerNotStarting),
            (.imageMissing, .imageMissing),
            (.failed(reason: "made-up reason for the log"), .serverFailed),
            (.notStarted, .serverFailed),
            (.starting, .serverFailed),
        ]
        for (state, phase) in table {
            let rig = ShellRig()
            rig.runtime.fakeServer.afterStart.value = state
            let model = rig.makeModel()
            await model.start()
            #expect(model.phase == phase, "server \(state)")
            #expect(model.signIn == nil)
            #expect(rig.owner.calls.isEmpty, "server \(state)")
        }
    }

    @Test("while Docker Desktop is starting the window says so, then moves on when it has")
    func showsDockerStarting() async {
        let server = SlowServer()
        let model = AppModel(
            runtime: SlowRuntime(server: server), makeOwnerAPI: { _, _ in FakeOwnerAPI() },
            pollInterval: .milliseconds(2))

        let launch = Task { await model.start() }
        #expect(await ShellFixtures.eventually { model.phase == .dockerStarting })

        server.finish.value = .dockerNotStarting
        await launch.value
        #expect(model.phase == .dockerNotStarting)
    }

    @Test("Check again starts the server again and carries on when it now runs")
    func checkAgain() async {
        let rig = ShellRig()
        rig.scriptSignIn(ownerExists: true)
        rig.runtime.fakeServer.afterStart.value = .dockerMissing
        let model = rig.makeModel()
        await model.start()
        #expect(model.phase == .dockerMissing)

        rig.runtime.fakeServer.afterStart.value = .running(apiBaseURL: ShellFixtures.apiURL)
        await model.checkAgain()

        #expect(model.phase == .signIn)
        #expect(rig.runtime.fakeServer.startCount.value == 2)
    }
}

@MainActor
@Suite("AppModel: the session")
struct AppModelSessionTests {
    private func signedInRig() async -> (ShellRig, AppModel) {
        let rig = ShellRig()
        rig.scriptSignIn(ownerExists: true)
        let model = rig.makeModel()
        await model.start()
        model.signIn?.email = ShellFixtures.madeUpEmail
        model.signIn?.password = ShellFixtures.madeUpPassword
        await model.signIn?.submit()
        return (rig, model)
    }

    @Test("signing in keeps the token, shows the app and starts the helper with the owner's session")
    func signInSucceeds() async {
        let (rig, model) = await signedInRig()

        #expect(model.phase == .ready)
        #expect(model.signIn == nil)
        #expect(rig.runtime.fakeSessions.token.value == ShellFixtures.madeUpSessionToken)
        #expect(rig.factoryCalls.value.last == FactoryCall(url: ShellFixtures.apiURL, token: ShellFixtures.madeUpSessionToken))
        #expect(await ShellFixtures.eventually { rig.runtime.fakeHelper.starts.value == [ShellFixtures.apiURL] })
    }

    @Test("a session that cannot be kept still works until the app is closed")
    func saveFails() async {
        let rig = ShellRig()
        rig.scriptSignIn(ownerExists: true)
        let model = rig.makeModel()
        await model.start()
        rig.runtime.fakeSessions.failure.value = URLError(.cannotWriteToFile)
        model.signIn?.email = ShellFixtures.madeUpEmail
        model.signIn?.password = ShellFixtures.madeUpPassword

        await model.signIn?.submit()

        #expect(model.phase == .ready)
    }

    @Test("the helper is started with an issuer that reaches issue_helper_token, and nothing else holds the token")
    func helperIssuer() async {
        let owner = FakeOwnerAPI()
        owner.script {
            $0.setupState = { SetupState(ownerExists: true) }
            $0.systemHealth = { ShellFixtures.health() }
            $0.issueHelperToken = { name, key in
                .completed(
                    .shown(HelperTokenIssued(helperID: UUID(), helperToken: "made-up-helper-token")),
                    key: key.value, command: .issueHelperToken)
            }
        }
        let helper = RecordingHelper()
        let sessions = FakeAppRuntime().fakeSessions
        sessions.token.value = "stored-made-up-token"
        let model = AppModel(
            runtime: RecordingRuntime(helper: helper, sessions: sessions), makeOwnerAPI: { _, _ in owner },
            pollInterval: .milliseconds(5))

        await model.start()
        #expect(await ShellFixtures.eventually { helper.issuer.value != nil })

        let token = try? await helper.issuer.value?.issueHelperToken(name: "This Mac", idempotencyKey: "made-up-key")
        #expect(token == "made-up-helper-token")
        #expect(owner.calls.last?.operation == .issueHelperToken)
        #expect(owner.calls.last?.body?["name"] == .string("This Mac"))
        #expect(owner.calls.last?.key?.value == "made-up-key")
    }

    @Test("Sign out ends the session on the server, forgets it here, stops the helper and shows Sign in")
    func signOut() async {
        let (rig, model) = await signedInRig()
        let feed = model.screens?.feed

        await model.signOut()

        #expect(rig.owner.calls.contains { $0.operation == .signOutOwner && $0.key != nil })
        #expect(rig.runtime.fakeSessions.token.value == nil)
        #expect(await ShellFixtures.eventually { rig.runtime.fakeHelper.stopCount.value == 1 })
        #expect(model.phase == .signIn)
        #expect(model.signIn?.mode == .signIn)
        #expect(model.screens == nil)
        #expect(feed?.connection == .idle)
    }

    @Test("Sign out signs out here even when the server cannot be asked")
    func signOutOffline() async {
        let (rig, model) = await signedInRig()
        rig.owner.script { $0.signOut = { _ in throw URLError(.notConnectedToInternet) } }

        await model.signOut()

        #expect(rig.runtime.fakeSessions.token.value == nil)
        #expect(model.phase == .signIn)
    }

    @Test("a 401 from any call on any screen returns the app to Sign in, once (MA-6)")
    func unauthenticatedAnywhere() async {
        let (rig, model) = await signedInRig()
        rig.owner.script { $0.board = { throw ShellFixtures.unauthenticated() } }
        let owner = try! #require(model.screens?.owner)

        await #expect(throws: TransportError.self) { _ = try await owner.board() }

        #expect(model.phase == .signIn)
        #expect(model.signIn?.mode == .signIn)
        #expect(rig.runtime.fakeSessions.token.value == nil)
        #expect(await ShellFixtures.eventually { rig.runtime.fakeHelper.stopCount.value == 1 })

        // A stale call finishing later changes nothing.
        await #expect(throws: TransportError.self) { _ = try await owner.board() }
        #expect(model.phase == .signIn)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(rig.runtime.fakeHelper.stopCount.value == 1)
    }

    @Test("any other failure of a call is passed on and leaves the session alone")
    func otherFailuresPassThrough() async {
        let (rig, model) = await signedInRig()
        rig.owner.script { $0.board = { throw URLError(.timedOut) } }
        let owner = try! #require(model.screens?.owner)

        await #expect(throws: URLError.self) { _ = try await owner.board() }

        #expect(model.phase == .ready)
        #expect(rig.runtime.fakeSessions.token.value == ShellFixtures.madeUpSessionToken)
    }

    @Test("quitting stops the helper and the events tail, once however often it is asked")
    func quit() async {
        let (rig, model) = await signedInRig()

        await model.prepareToQuit()
        await model.prepareToQuit()

        #expect(rig.runtime.fakeHelper.stopCount.value == 1)
        #expect(model.screens?.feed.connection ?? .idle == .idle)
        // The owner stays signed in for the next launch.
        #expect(rig.runtime.fakeSessions.token.value == ShellFixtures.madeUpSessionToken)
    }
}

@MainActor
@Suite("AppDelegate")
struct AppDelegateTests {
    @Test("closing the window does not quit the app (PK-8)")
    func staysRunning() {
        #expect(AppDelegate().applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared) == false)
    }

    @Test("clicking the Dock icon with no window open opens the window; with one open it does nothing")
    func reopens() {
        let delegate = AppDelegate()
        let opened = Locked(0)
        delegate.openMainWindow = { opened.update { $0 += 1 } }

        let handledA = delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false)
        #expect(opened.value == 1)
        #expect(handledA == false)

        _ = delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: true)
        #expect(opened.value == 1)
    }

    @Test("quitting with nothing to wait for quits at once")
    func quitsAtOnce() {
        let delegate = AppDelegate()
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateNow)
    }

    @Test("quitting waits for the helper to stop, then replies that the app may quit")
    func quitsLater() async {
        let delegate = AppDelegate()
        let finished = Locked(false)
        let replies = Locked<[Bool]>([])
        delegate.terminationWork = { try? await Task.sleep(for: .milliseconds(20)); finished.value = true }
        delegate.replyToTermination = { allow in replies.update { $0.append(allow) } }

        let answer = delegate.applicationShouldTerminate(NSApplication.shared)

        #expect(answer == .terminateLater)
        #expect(replies.value.isEmpty)
        #expect(await ShellFixtures.eventually { replies.value == [true] })
        #expect(finished.value)
    }
}
