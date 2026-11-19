import Foundation
import LeverageKit
import LeverageTestSupport

@testable import LeverageApp

/// What the shell's tests share: made-up values and a rig that builds an
/// `AppModel` on the fakes. Nothing here touches the network, Docker or the
/// Keychain.
enum ShellFixtures {
    static let apiURL = URL(string: "http://127.0.0.1:47130")!
    /// Obviously not a token; the made-up value tests use for a session.
    static let madeUpSessionToken = "made-up-session-token"
    static let madeUpEmail = "owner@example.invalid"
    static let madeUpPassword = "made-up-password"

    static func unauthenticated() -> TransportError {
        TransportError(code: .unauthenticated, message: "Sign in again.")
    }

    static func sessionAnswer(key: String, command: CommandName) -> CommandOutcome<OwnerSessionAnswer> {
        .completed(
            .shown(OwnerSession(userID: UUID(), sessionToken: madeUpSessionToken, createdAt: Date())),
            key: key, command: command)
    }

    static func repeatedAnswer(key: String, command: CommandName) -> CommandOutcome<OwnerSessionAnswer> {
        .completed(
            .repeated(OwnerSessionRepeated(userID: UUID(), createdAt: Date())), key: key, command: command)
    }

    static func health(sweepLate: Bool = false) -> SystemHealth {
        SystemHealth(
            sweepLastRanAt: Date(), sweepLate: sweepLate, helperLastReportedAt: Date(), queuedHelperRequests: 0,
            readyTasks: 0, waitingReviews: 0)
    }

    static func event(seq: Int) -> EventRecord {
        EventRecord(id: UUID(), workspaceID: UUID(), seq: seq, at: Date(), type: .taskCreated, actorKind: .owner)
    }

    /// Waits, at most `timeout` times the run's patience, until `condition`
    /// holds; returns whether it did.
    @MainActor
    static func eventually(
        timeout: Duration = .seconds(20), _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + Patience.scaled(timeout)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            // Every app test runs on the main actor: a looser look leaves
            // it to the code under test.
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}

/// One address and token the app asked its owner-API factory for.
struct FactoryCall: Equatable, Sendable {
    let url: URL
    let token: String?
}

/// An `AppModel` on the fakes, with its calls to the owner-API factory
/// recorded. Every API the factory builds is the same `FakeOwnerAPI`.
@MainActor
final class ShellRig {
    let runtime = FakeAppRuntime()
    let owner = FakeOwnerAPI()
    let factoryCalls = Locked<[FactoryCall]>([])

    func makeModel(pollInterval: Duration = .milliseconds(5)) -> AppModel {
        let owner = owner
        let calls = factoryCalls
        return AppModel(
            runtime: runtime,
            makeOwnerAPI: { url, token in
                calls.update { $0.append(FactoryCall(url: url, token: token)) }
                return owner
            },
            pollInterval: pollInterval)
    }

    /// The owner answers the setup read, and the sign-in and setup commands
    /// with a made-up session.
    func scriptSignIn(ownerExists: Bool) {
        owner.script {
            $0.setupState = { SetupState(ownerExists: ownerExists) }
            $0.createOwner = { _, key in ShellFixtures.sessionAnswer(key: key.value, command: .createOwner) }
            $0.signIn = { _, key in ShellFixtures.sessionAnswer(key: key.value, command: .signIn) }
            $0.signOut = { key in .completed(.object([:]), key: key.value, command: .signOut) }
            $0.systemHealth = { ShellFixtures.health() }
        }
    }
}
