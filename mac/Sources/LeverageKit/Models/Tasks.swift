import Foundation

// The task and what hangs off it, as the contract's components describe
// them. A response model is Codable for the fakes and tests; the server's
// answers are only ever decoded.

/// `TaskSummary`: one task's own fields.
public struct TaskSummary: Codable, Equatable, Sendable {
    public let id: UUID
    public let projectID: UUID?
    public let title: String
    public let goal: String
    public let details: String?
    public let state: TaskState
    public let round: Int
    public let holderSeatID: UUID?
    public let builderSeatID: UUID?
    public let leaseDueAt: Date?
    /// Seconds of lease left while the clock is paused.
    public let leaseTimeLeftWhilePaused: Int?
    public let minimumStrengthRank: Int?
    public let contractVersion: Int
    public let budgetCap: Decimal?
    public let spent: Decimal
    public let workReference: String?
    public let priority: Priority

    public init(
        id: UUID, projectID: UUID? = nil, title: String, goal: String, details: String? = nil,
        state: TaskState, round: Int = 0, holderSeatID: UUID? = nil, builderSeatID: UUID? = nil,
        leaseDueAt: Date? = nil, leaseTimeLeftWhilePaused: Int? = nil, minimumStrengthRank: Int? = nil,
        contractVersion: Int = 0, budgetCap: Decimal? = nil, spent: Decimal = 0, workReference: String? = nil,
        priority: Priority = .normal
    ) {
        self.id = id
        self.projectID = projectID
        self.title = title
        self.goal = goal
        self.details = details
        self.state = state
        self.round = round
        self.holderSeatID = holderSeatID
        self.builderSeatID = builderSeatID
        self.leaseDueAt = leaseDueAt
        self.leaseTimeLeftWhilePaused = leaseTimeLeftWhilePaused
        self.minimumStrengthRank = minimumStrengthRank
        self.contractVersion = contractVersion
        self.budgetCap = budgetCap
        self.spent = spent
        self.workReference = workReference
        self.priority = priority
    }

    enum CodingKeys: String, CodingKey {
        case id, title, goal, details, state, round, spent, priority
        case projectID = "project_id"
        case holderSeatID = "holder_seat_id"
        case builderSeatID = "builder_seat_id"
        case leaseDueAt = "lease_due_at"
        case leaseTimeLeftWhilePaused = "lease_time_left_while_paused"
        case minimumStrengthRank = "minimum_strength_rank"
        case contractVersion = "contract_version"
        case budgetCap = "budget_cap"
        case workReference = "work_reference"
    }
}

/// `Evidence`: proof attached to a criterion when it passed.
public struct CriterionEvidence: Codable, Equatable, Sendable {
    public let id: UUID
    public let criterionID: UUID
    public let kind: EvidenceKind
    public let value: String

    public init(id: UUID, criterionID: UUID, kind: EvidenceKind, value: String) {
        self.id = id
        self.criterionID = criterionID
        self.kind = kind
        self.value = value
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, value
        case criterionID = "criterion_id"
    }
}

/// `Criterion`: one acceptance criterion of a task's contract.
public struct Criterion: Codable, Equatable, Sendable {
    public let id: UUID
    public let taskID: UUID
    public let position: Int
    public let text: String
    public let kind: CriterionKind
    public let state: CriterionState
    public let passedAt: Date?
    public let passedBySeatID: UUID?
    public let evidence: [CriterionEvidence]

    public init(
        id: UUID, taskID: UUID, position: Int, text: String, kind: CriterionKind, state: CriterionState,
        passedAt: Date? = nil, passedBySeatID: UUID? = nil, evidence: [CriterionEvidence] = []
    ) {
        self.id = id
        self.taskID = taskID
        self.position = position
        self.text = text
        self.kind = kind
        self.state = state
        self.passedAt = passedAt
        self.passedBySeatID = passedBySeatID
        self.evidence = evidence
    }

    enum CodingKeys: String, CodingKey {
        case id, position, text, kind, state, evidence
        case taskID = "task_id"
        case passedAt = "passed_at"
        case passedBySeatID = "passed_by_seat_id"
    }
}

/// `Action`: an outward action in a task's contract.
public struct OutwardAction: Codable, Equatable, Sendable {
    public let id: UUID
    public let taskID: UUID
    public let kind: ActionKind
    public let description: String
    public let state: ActionState
    public let approvedByKind: ActorKind?
    public let approvedByID: UUID?
    public let approvedAt: Date?
    public let position: Int
    public let stoppedByRuleCheckID: UUID?

    public init(
        id: UUID, taskID: UUID, kind: ActionKind, description: String, state: ActionState,
        approvedByKind: ActorKind? = nil, approvedByID: UUID? = nil, approvedAt: Date? = nil,
        position: Int = 1, stoppedByRuleCheckID: UUID? = nil
    ) {
        self.id = id
        self.taskID = taskID
        self.kind = kind
        self.description = description
        self.state = state
        self.approvedByKind = approvedByKind
        self.approvedByID = approvedByID
        self.approvedAt = approvedAt
        self.position = position
        self.stoppedByRuleCheckID = stoppedByRuleCheckID
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, description, state, position
        case taskID = "task_id"
        case approvedByKind = "approved_by_kind"
        case approvedByID = "approved_by_id"
        case approvedAt = "approved_at"
        case stoppedByRuleCheckID = "stopped_by_rule_check_id"
    }
}

public typealias Action = OutwardAction

/// `Review`: one review of one round of a task.
public struct Review: Codable, Equatable, Sendable {
    public let id: UUID
    public let taskID: UUID
    public let round: Int
    public let reviewerSeatID: UUID?
    public let leaseDueAt: Date?
    public let verdict: ReviewVerdict?
    public let failedCriteria: [UUID]
    public let notes: String?

    public init(
        id: UUID, taskID: UUID, round: Int, reviewerSeatID: UUID? = nil, leaseDueAt: Date? = nil,
        verdict: ReviewVerdict? = nil, failedCriteria: [UUID] = [], notes: String? = nil
    ) {
        self.id = id
        self.taskID = taskID
        self.round = round
        self.reviewerSeatID = reviewerSeatID
        self.leaseDueAt = leaseDueAt
        self.verdict = verdict
        self.failedCriteria = failedCriteria
        self.notes = notes
    }

    enum CodingKeys: String, CodingKey {
        case id, round, verdict, notes
        case taskID = "task_id"
        case reviewerSeatID = "reviewer_seat_id"
        case leaseDueAt = "lease_due_at"
        case failedCriteria = "failed_criteria"
    }
}

/// `ReviewNote`: the notes of a failed review, given back to the builder
/// with its briefing.
public struct ReviewNote: Codable, Equatable, Sendable {
    public let reviewID: UUID
    public let round: Int
    public let notes: String?

    public init(reviewID: UUID, round: Int, notes: String?) {
        self.reviewID = reviewID
        self.round = round
        self.notes = notes
    }

    enum CodingKeys: String, CodingKey {
        case round, notes
        case reviewID = "review_id"
    }
}

/// `Question`: a question a seat asked about a task.
public struct Question: Codable, Equatable, Sendable {
    public let id: UUID
    public let taskID: UUID
    public let askingSeatID: UUID
    public let text: String
    public let assumption: String
    public let blocking: Bool
    public let outcome: QuestionOutcome
    public let answer: String?
    public let basis: QuestionBasis?
    public let answeredByKind: ActorKind?
    public let answeredByID: UUID?
    public let askedAt: Date
    public let answeredAt: Date?
    public let overturned: Bool

    public init(
        id: UUID, taskID: UUID, askingSeatID: UUID, text: String, assumption: String, blocking: Bool,
        outcome: QuestionOutcome, answer: String? = nil, basis: QuestionBasis? = nil,
        answeredByKind: ActorKind? = nil, answeredByID: UUID? = nil,
        askedAt: Date = Date(timeIntervalSince1970: 0), answeredAt: Date? = nil, overturned: Bool = false
    ) {
        self.id = id
        self.taskID = taskID
        self.askingSeatID = askingSeatID
        self.text = text
        self.assumption = assumption
        self.blocking = blocking
        self.outcome = outcome
        self.answer = answer
        self.basis = basis
        self.answeredByKind = answeredByKind
        self.answeredByID = answeredByID
        self.askedAt = askedAt
        self.answeredAt = answeredAt
        self.overturned = overturned
    }

    enum CodingKeys: String, CodingKey {
        case id, text, assumption, blocking, outcome, answer, basis, overturned
        case taskID = "task_id"
        case askingSeatID = "asking_seat_id"
        case answeredByKind = "answered_by_kind"
        case answeredByID = "answered_by_id"
        case askedAt = "asked_at"
        case answeredAt = "answered_at"
    }
}

/// `Hold`: a hold on a task or a project.
public struct Hold: Codable, Equatable, Sendable {
    public let id: UUID
    public let taskID: UUID?
    public let projectID: UUID?
    public let reason: HoldReason
    public let ruleID: UUID?
    public let credentialID: UUID?
    public let openedAt: Date
    public let closedAt: Date?

    public init(
        id: UUID, taskID: UUID?, projectID: UUID? = nil, reason: HoldReason, ruleID: UUID? = nil,
        credentialID: UUID? = nil, openedAt: Date, closedAt: Date? = nil
    ) {
        self.id = id
        self.taskID = taskID
        self.projectID = projectID
        self.reason = reason
        self.ruleID = ruleID
        self.credentialID = credentialID
        self.openedAt = openedAt
        self.closedAt = closedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, reason
        case taskID = "task_id"
        case projectID = "project_id"
        case ruleID = "rule_id"
        case credentialID = "credential_id"
        case openedAt = "opened_at"
        case closedAt = "closed_at"
    }
}

/// `InboxItem`: a Needs you item.
public struct InboxItem: Codable, Equatable, Sendable {
    public let id: UUID
    public let kind: NeedsYouItem
    public let aboutKind: InboxAboutKind
    public let aboutID: UUID
    public let holdID: UUID?
    public let credentialID: UUID?
    public let choices: [InboxChoice]
    /// The facts its kind stores (`needs_you.json`).
    public let facts: [String: JSONValue]
    public var detail: String? { nil }
    public let state: InboxState
    public let openedAt: Date
    public let openedSeq: Int
    public let resolvedByKind: ActorKind?
    public let resolvedByID: UUID?
    public let resolvedAt: Date?

    public init(
        id: UUID, kind: NeedsYouItem, aboutKind: InboxAboutKind, aboutID: UUID, holdID: UUID? = nil,
        credentialID: UUID? = nil, choices: [InboxChoice], facts: [String: JSONValue] = [:],
        state: InboxState = .open, openedAt: Date, openedSeq: Int, resolvedByKind: ActorKind? = nil,
        resolvedByID: UUID? = nil, resolvedAt: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.aboutKind = aboutKind
        self.aboutID = aboutID
        self.holdID = holdID
        self.credentialID = credentialID
        self.choices = choices
        self.facts = facts
        self.state = state
        self.openedAt = openedAt
        self.openedSeq = openedSeq
        self.resolvedByKind = resolvedByKind
        self.resolvedByID = resolvedByID
        self.resolvedAt = resolvedAt
    }

    public var questionID: UUID? {
        factID("question_id")
    }

    public var actionID: UUID? {
        factID("action_id")
    }

    public var actionIDs: [UUID] {
        facts["action_ids"]?.arrayValue?.compactMap { $0.stringValue.flatMap(UUID.init(uuidString:)) } ?? []
    }

    public var ruleCheckID: UUID? {
        factID("rule_check_id")
    }

    public var anyActionStarted: Bool? {
        facts["any_action_started"]?.boolValue
    }

    public var approvedByKind: ActorKind? {
        facts["approved_by_kind"]?.stringValue.flatMap(ActorKind.init(rawValue:))
    }

    public var approvedByID: UUID? {
        factID("approved_by_id")
    }

    public var builderAnnouncedStart: Bool? {
        facts["builder_announced_start"]?.boolValue
    }

    private func factID(_ name: String) -> UUID? {
        facts[name]?.stringValue.flatMap(UUID.init(uuidString:))
    }

    /// The checks waiting, for an open `orchestrator_offline` item: the count
    /// now, not the count when it opened (RD-18). Nil for any other item.
    public var waitingChecks: Int? {
        guard case .number(let count)? = facts["waiting_checks"], count >= 0, count.rounded() == count else { return nil }
        return Int(count)
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, choices, facts, state
        case aboutKind = "about_kind"
        case aboutID = "about_id"
        case holdID = "hold_id"
        case credentialID = "credential_id"
        case openedAt = "opened_at"
        case openedSeq = "opened_seq"
        case resolvedByKind = "resolved_by_kind"
        case resolvedByID = "resolved_by_id"
        case resolvedAt = "resolved_at"
    }
}
