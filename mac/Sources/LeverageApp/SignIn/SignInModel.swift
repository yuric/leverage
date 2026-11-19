import Foundation
import LeverageKit
import Observation

/// Create the sign-in on a new installation, or sign in (IN-2, MA-5).
///
/// One command at a time. The key of a command that could not be answered
/// (the server was not reached) is kept, so pressing the button again sends
/// the same command and a repeat writes nothing twice; it is dropped when
/// the owner changes what was typed, because the server refuses one key with
/// two bodies. A repeat that is answered without a token (`repeated`) is
/// sent again with a new key, as IN-9 says.
@MainActor
@Observable
final class SignInModel {
    enum Mode: Equatable, Sendable { case create, signIn }

    enum State: Equatable, Sendable {
        case idle
        case busy
        case signedIn
        case failed(SignInCopy)
    }

    private(set) var mode: Mode
    private(set) var state: State = .idle

    var email = "" { didSet { if email != oldValue { forgetKey() } } }
    var password = "" { didSet { if password != oldValue { forgetKey() } } }

    @ObservationIgnored private let api: any OwnerAPI
    @ObservationIgnored private let onSignedIn: @MainActor (String) -> Void
    @ObservationIgnored private var pendingKey: IdempotencyKey?

    /// A new password is at least this long (IN-4).
    static let minimumNewPasswordLength = 8

    init(mode: Mode, api: any OwnerAPI, onSignedIn: @escaping @MainActor (String) -> Void) {
        self.mode = mode
        self.api = api
        self.onSignedIn = onSignedIn
    }

    private var trimmedEmail: String { email.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Whether the button is on.
    var canSubmit: Bool {
        guard state != .busy, state != .signedIn else { return false }
        guard trimmedEmail.contains("@"), trimmedEmail.count >= 3, !password.isEmpty else { return false }
        return mode == .signIn || password.count >= Self.minimumNewPasswordLength
    }

    var isBusy: Bool { state == .busy }

    /// The line to show under the fields, if any.
    var failure: SignInCopy? {
        if case .failed(let copy) = state { copy } else { nil }
    }

    private func forgetKey() { pendingKey = nil }

    /// Sends Create sign-in or Sign in.
    func submit() async {
        guard canSubmit else { return }
        state = .busy
        let key = pendingKey ?? IdempotencyKey()
        pendingKey = key
        let request = SignInRequest(emailAddress: trimmedEmail, password: password)
        do {
            if let token = try await send(request, key: key) {
                pendingKey = nil
                state = .signedIn
                onSignedIn(token)
            } else {
                // Answered with no token: sign in again with a new key.
                let fresh = IdempotencyKey()
                pendingKey = fresh
                if let token = try await send(request, key: fresh) {
                    pendingKey = nil
                    state = .signedIn
                    onSignedIn(token)
                } else {
                    state = .failed(.somethingWentWrong)
                }
            }
        } catch {
            state = .failed(failureLine(for: error))
        }
    }

    /// The session token of the answer, or nil for a repeat that carries none.
    private func send(_ request: SignInRequest, key: IdempotencyKey) async throws -> String? {
        let outcome: CommandOutcome<OwnerSessionAnswer>
        switch mode {
        case .create: outcome = try await api.createOwner(request, key: key)
        case .signIn: outcome = try await api.signIn(request, key: key)
        }
        switch try outcome.completedResult() {
        case .shown(let session): return session.sessionToken
        case .repeated, nil: return nil
        }
    }

    private func failureLine(for error: any Error) -> SignInCopy {
        switch error {
        case let error as TransportError:
            switch error.code {
            case .unauthenticated: return .wrongDetails
            case .notFound:
                if mode == .create {
                    mode = .signIn
                    return .alreadyCreated
                }
                return .somethingWentWrong
            case .invalid: return .invalidDetails
            case .malformed, .keyReused: return .somethingWentWrong
            }
        case is URLError: return .cannotReach
        default: return .somethingWentWrong
        }
    }
}
