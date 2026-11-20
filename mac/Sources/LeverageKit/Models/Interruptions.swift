import Foundation

/// The work an interruption report names: exactly one of a task, a review
/// and a job, as the schema's `oneOf` says (IF-28).
public enum InterruptedWork: Equatable, Sendable {
    case task(UUID)
    case review(UUID)
    case job(UUID)
}

/// `LimitReport`: a run hit a provider limit; what the helper sends through
/// `report_limit` (IF-28, HD-10). Never the tool's reply.
public struct LimitReport: Encodable, Equatable, Sendable {
    public let credentialID: UUID
    public let seatID: UUID
    public let work: InterruptedWork
    public let window: LimitWindow
    /// Nil when the provider gave none.
    public let resetAt: Date?
    public let observedAt: Date
    public let toolVersion: String

    public init(
        credentialID: UUID, seatID: UUID, work: InterruptedWork, window: LimitWindow, resetAt: Date?,
        observedAt: Date, toolVersion: String
    ) {
        self.credentialID = credentialID
        self.seatID = seatID
        self.work = work
        self.window = window
        self.resetAt = resetAt
        self.observedAt = observedAt
        self.toolVersion = toolVersion
    }

    public func encode(to encoder: any Encoder) throws {}
}

/// `SignOutReport`: a login was found signed out during a run; what the
/// helper sends through `report_signed_out` (IF-28, HD-10).
public struct SignOutReport: Encodable, Equatable, Sendable {
    public let credentialID: UUID
    public let seatID: UUID
    public let work: InterruptedWork
    public let observedAt: Date
    public let toolVersion: String

    public init(credentialID: UUID, seatID: UUID, work: InterruptedWork, observedAt: Date, toolVersion: String) {
        self.credentialID = credentialID
        self.seatID = seatID
        self.work = work
        self.observedAt = observedAt
        self.toolVersion = toolVersion
    }

    public func encode(to encoder: any Encoder) throws {}
}
