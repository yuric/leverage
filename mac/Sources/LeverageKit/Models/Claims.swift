import Foundation

/// `NextItem`: what `GET /v1/next` answers, the first true item of the
/// precedence table. It is not consumed: it repeats until the seat acts.
public struct NextItem: Codable, Equatable, Sendable {
    public let kind: NextKind
    /// The task, the question or, for `command`, the command's key; nil for
    /// `review`, `job`, `task` and `none`.
    public let id: String?
    /// Set only for `briefing_changed` when the seat holds a review.
    public let reviewID: UUID?

    public init(kind: NextKind, id: String? = nil, reviewID: UUID? = nil) {
        self.kind = kind
        self.id = id
        self.reviewID = reviewID
    }

    enum CodingKeys: String, CodingKey {
        case kind, id
        case reviewID = "review_id"
    }
}

/// `Lease`: who holds a lease and when it ends.
public struct Lease: Codable, Equatable, Sendable {
    public let seatID: UUID
    public let leaseDueAt: Date

    public init(seatID: UUID, leaseDueAt: Date) {
        self.seatID = seatID
        self.leaseDueAt = leaseDueAt
    }

    enum CodingKeys: String, CodingKey {
        case seatID = "seat_id"
        case leaseDueAt = "lease_due_at"
    }
}

/// `HeartbeatResult`: the renewed lease's end.
public struct HeartbeatResult: Codable, Equatable, Sendable {
    public let leaseDueAt: Date

    public init(leaseDueAt: Date) {
        self.leaseDueAt = leaseDueAt
    }

    enum CodingKeys: String, CodingKey {
        case leaseDueAt = "lease_due_at"
    }
}

/// `ClaimTaskResult`: a claimed task with its lease and briefing, and the
/// seat's credential and model (EN-7).
public struct TaskClaim: Codable, Equatable, Sendable {
    public let task: TaskSummary
    public let lease: Lease
    public let briefing: Briefing
    public let workReference: String?
    /// Null for a seat that connects on its own.
    public let credentialID: UUID?
    /// Null for the tool's default.
    public let model: String?

    public init(
        task: TaskSummary, lease: Lease, briefing: Briefing, workReference: String?, credentialID: UUID?,
        model: String?
    ) {
        self.task = task
        self.lease = lease
        self.briefing = briefing
        self.workReference = workReference
        self.credentialID = credentialID
        self.model = model
    }

    enum CodingKeys: String, CodingKey {
        case task, lease, briefing, model
        case workReference = "work_reference"
        case credentialID = "credential_id"
    }
}

/// `ClaimReviewResult`: a claimed review with its lease and briefing, and
/// the seat's credential and model (EN-7).
public struct ReviewClaim: Codable, Equatable, Sendable {
    public let review: Review
    public let lease: Lease
    public let briefing: Briefing
    public let workReference: String?
    public let credentialID: UUID?
    public let model: String?

    public init(
        review: Review, lease: Lease, briefing: Briefing, workReference: String?, credentialID: UUID?,
        model: String?
    ) {
        self.review = review
        self.lease = lease
        self.briefing = briefing
        self.workReference = workReference
        self.credentialID = credentialID
        self.model = model
    }

    enum CodingKeys: String, CodingKey {
        case review, lease, briefing, model
        case workReference = "work_reference"
        case credentialID = "credential_id"
    }
}
