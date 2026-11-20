import Foundation

/// What a detector found when it looked at one failed tool run (plan HD-5,
/// HD-7). It carries no word of the tool's reply: only the kind, and for a
/// limit the window and the reset time the reply stated.
public enum RunOutcome: Equatable, Sendable {
    /// The account reached a limit that names one of the four windows.
    /// `resetAt` is the time the reply stated, or nil when it stated none;
    /// it is never estimated (L615).
    case limit(window: LimitWindow, resetAt: Date?)
    /// A short rate limit that names no window: retried in place (HD-7).
    case rateLimited
    /// The account is signed out.
    case signedOut
    /// Anything else: milestone 2's failure (CL-22), unchanged.
    case failed

    /// The kind alone, which is all a log may say of an outcome.
    public var name: String {
        switch self {
        case .limit: "limit"
        case .rateLimited: "rate_limited"
        case .signedOut: "signed_out"
        case .failed: "failed"
        }
    }

    /// True when the run ends and the account is reported (HD-6): a limit
    /// or a sign-out.
    public var stopsTheAccount: Bool {
        switch self {
        case .limit, .signedOut: true
        case .rateLimited, .failed: false
        }
    }
}
