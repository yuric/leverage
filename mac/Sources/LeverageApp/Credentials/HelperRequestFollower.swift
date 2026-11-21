import Foundation
import LeverageKit

/// How long the app waits and how often it asks while it follows a helper
/// request (IN-23). Tests pass short ones.
struct FollowTiming: Sendable {
    /// The long poll's wait, in seconds.
    let waitSeconds: Int
    /// The pause when an answer came back with nothing new.
    let idleDelay: Duration
    /// The pause before asking again after the network failed.
    let retryDelay: Duration
    /// How long the app follows a request that checks a login or adds one:
    /// the helper itself waits up to 10 minutes for a sign-in (CL-19).
    let giveUpAfter: Duration

    /// How long it follows a Start or a Stop, which are quick.
    var quickGiveUpAfter: Duration { min(giveUpAfter, .seconds(90)) }

    static let normal = FollowTiming(
        waitSeconds: 20, idleDelay: .seconds(1), retryDelay: .seconds(2), giveUpAfter: .seconds(15 * 60))
}

/// Follows one helper request with `get_helper_request` until it finishes or
/// fails (IN-23): each ask carries the time of the last change seen, so the
/// server answers when something changed or the wait ran out.
struct HelperRequestFollower: Sendable {
    let api: any OwnerAPI
    let timing: FollowTiming

    /// Calls `update` with every answer, and returns the request once it has
    /// finished or failed, or nil when `giveUpAfter` ran out first. A network
    /// error is waited out; any other error is thrown, and so is a cancel.
    func follow(
        _ id: UUID, giveUpAfter: Duration, update: @MainActor (HelperRequest) -> Void = { _ in }
    ) async throws -> HelperRequest? {
        let deadline = ContinuousClock.now + giveUpAfter
        var changedAfter: Date?
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            do {
                let status = try await api.helperRequest(id: id, wait: timing.waitSeconds, changedAfter: changedAfter)
                let request = status.request
                await update(request)
                if request.state == .finished || request.state == .failed { return request }
                if changedAfter == request.updatedAt { try await Task.sleep(for: timing.idleDelay) }
                changedAfter = request.updatedAt
            } catch let error as URLError where error.code != .cancelled {
                try await Task.sleep(for: timing.retryDelay)
            }
        }
        return nil
    }
}

extension HelperRequest {
    /// Whether the request ended with every check passed.
    var succeeded: Bool {
        switch state {
        case .finished: result?.outcome != .failed
        case .failed: false
        case .queued, .pickedUp: false
        }
    }

    /// The check that failed and why, from the progress the helper reported
    /// or else from its result.
    var failedCheck: (check: HelperCheck, failure: HelperCheckFailure?)? {
        if let progress = self.progress.last(where: { $0.state == .failed }) {
            return (progress.check, progress.failure)
        }
        if let check = result?.checks.first(where: { !$0.passed }) { return (check.check, check.failure) }
        return nil
    }
}

extension CredentialsCopy {
    /// The one line for a request that failed: which tool, and what it did
    /// not do.
    static func failureLine(for request: HelperRequest, provider: Provider) -> String {
        guard let failure = request.failedCheck?.failure else { return failedGeneric.text }
        if provider.kind == .apiToken {
            return AddTokenCopy.failureLine(for: failure, provider: ProviderNames.name(provider))
        }
        let tool = ProviderNames.tool(provider)
        let copy: CredentialsCopy
        switch failure {
        case .tokenStoreUnavailable, .providerMismatch: return failedGeneric.text
        case .notInstalled: copy = .failNotInstalled
        case .notSignedIn: copy = .failNotSignedIn
        case .noAnswer: copy = .failNoAnswer
        case .rejected: copy = .failRejected
        case .unreachable: copy = .failUnreachable
        case .timedOut: copy = .failTimedOut
        }
        return copy.filled(["tool": tool])
    }
}
