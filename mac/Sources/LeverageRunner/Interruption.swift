import Foundation
import LeverageKit

/// What the runner does after a failed tool run (plan §2.2, HD-5): ask the
/// provider's detector, retry a short rate limit in place, ask
/// `SignInStatus` when the output does not settle it, and decide between
/// "go on as milestone 2 does" and "this account stopped". It logs the
/// outcome's kind and nothing a tool printed. WP11 writes the rules; this
/// first version answers that every run goes on as before.
struct Interruption: Sendable {
    /// What follows a failed run.
    enum Decision: Equatable, Sendable {
        /// Not an interruption: CL-22's failure, as milestone 2 treats it.
        case goOnAsBefore
        /// The account stopped: end the tool and the heartbeat, release
        /// nothing, and hand the report to `main`.
        case accountStopped(RunOutcome)
    }

    /// The seat's provider.
    let provider: Provider
    /// Whether the seat runs on a login of its own; a run with no
    /// credential detects nothing (HM-19).
    let hasCredential: Bool

    init(provider: Provider, hasCredential: Bool) {
        self.provider = provider
        self.hasCredential = hasCredential
    }

    /// The decision after `record`, the failed run that ended at `now`.
    func decide(after record: ToolRunRecord, at now: Date) async -> Decision {
        .goOnAsBefore
    }
}
