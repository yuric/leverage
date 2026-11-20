import Foundation

public enum RunOutcome: Equatable, Sendable {
    case limit(window: LimitWindow, resetAt: Date?)
    case rateLimited
    case signedOut
    case failed

    public var name: String { "" }
    public var stopsTheAccount: Bool { false }
}
