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

    enum CodingKeys: String, CodingKey {
        case window
        case credentialID = "credential_id"
        case seatID = "seat_id"
        case taskID = "task_id"
        case reviewID = "review_id"
        case jobID = "job_id"
        case resetAt = "reset_at"
        case observedAt = "observed_at"
        case toolVersion = "tool_version"
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeID(credentialID, forKey: .credentialID)
        try container.encodeID(seatID, forKey: .seatID)
        try container.encodeWork(work, taskID: .taskID, reviewID: .reviewID, jobID: .jobID)
        try container.encode(window, forKey: .window)
        try container.encode(resetAt, forKey: .resetAt)
        try container.encode(observedAt, forKey: .observedAt)
        try container.encode(toolVersion, forKey: .toolVersion)
    }
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

    enum CodingKeys: String, CodingKey {
        case credentialID = "credential_id"
        case seatID = "seat_id"
        case taskID = "task_id"
        case reviewID = "review_id"
        case jobID = "job_id"
        case observedAt = "observed_at"
        case toolVersion = "tool_version"
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeID(credentialID, forKey: .credentialID)
        try container.encodeID(seatID, forKey: .seatID)
        try container.encodeWork(work, taskID: .taskID, reviewID: .reviewID, jobID: .jobID)
        try container.encode(observedAt, forKey: .observedAt)
        try container.encode(toolVersion, forKey: .toolVersion)
    }
}

extension KeyedEncodingContainer {
    /// Writes the three work fields of a report: the one that is named holds
    /// its id and the other two are null, as the schema's `oneOf` needs.
    fileprivate mutating func encodeWork(_ work: InterruptedWork, taskID: Key, reviewID: Key, jobID: Key) throws {
        var task: UUID?, review: UUID?, job: UUID?
        switch work {
        case .task(let id): task = id
        case .review(let id): review = id
        case .job(let id): job = id
        }
        try encodeID(task, forKey: taskID)
        try encodeID(review, forKey: reviewID)
        try encodeID(job, forKey: jobID)
    }
}
