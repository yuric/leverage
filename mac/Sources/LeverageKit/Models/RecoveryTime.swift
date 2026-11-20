import Foundation

/// `RecoveryTime.kind`: what stopped the work (HE-17). The words of
/// `RunStoppedReport.stop_reason` that start a recovery time.
public enum RecoveryKind: String, Codable, CaseIterable, Sendable {
    case limit
    case signedOut = "signed_out"
}

/// `RecoveryTime.ended_by`: how the work went on (HE-17).
public enum RecoveryEndedBy: String, Codable, CaseIterable, Sendable {
    /// Another account took over in the command that wrote the start.
    case handoff
    /// The continuing seat's first event of that work ended it.
    case seatEvent = "seat_event"
    /// The task was cancelled or done first.
    case notRecovered = "not_recovered"
}

/// `RecoveryTime`: one interruption of a task and how long the work was
/// stopped, computed by the server from the task's events (HE-17).
public struct RecoveryTime: Codable, Equatable, Sendable {
    public let kind: RecoveryKind
    /// The account that stopped.
    public let credentialID: UUID
    /// The review that was interrupted; nil for the task's build work.
    public let reviewID: UUID?
    public let startedAt: Date
    /// Nil while it is open, or when the task was cancelled or done first.
    public let endedAt: Date?
    /// Nil when it was not recovered; measured to the read while open.
    public let seconds: Int?
    /// Nil while it is open.
    public let endedBy: RecoveryEndedBy?

    public init(
        kind: RecoveryKind, credentialID: UUID, reviewID: UUID? = nil, startedAt: Date, endedAt: Date? = nil,
        seconds: Int? = nil, endedBy: RecoveryEndedBy? = nil
    ) {
        self.kind = kind
        self.credentialID = credentialID
        self.reviewID = reviewID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.seconds = seconds
        self.endedBy = endedBy
    }

    enum CodingKeys: String, CodingKey {
        case kind, seconds
        case credentialID = "credential_id"
        case reviewID = "review_id"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case endedBy = "ended_by"
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encodeID(credentialID, forKey: .credentialID)
        try container.encodeID(reviewID, forKey: .reviewID)
        try container.encode(startedAt, forKey: .startedAt)
        try container.encode(endedAt, forKey: .endedAt)
        try container.encode(seconds, forKey: .seconds)
        try container.encode(endedBy, forKey: .endedBy)
    }
}
