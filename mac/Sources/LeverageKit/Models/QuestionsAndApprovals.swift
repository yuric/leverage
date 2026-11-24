import Foundation

/// The question an agent's request created.
public struct AskQuestionResult: Codable, Equatable, Sendable {
    public let questionID: UUID

    public init(questionID: UUID) {
        self.questionID = questionID
    }

    enum CodingKeys: String, CodingKey {
        case questionID = "question_id"
    }
}

/// An answer included in a briefing or given to the orchestrator as context.
public struct AnsweredQuestion: Codable, Equatable, Sendable {
    public let text: String
    public let answer: String
    public let basis: QuestionBasis

    public init(text: String, answer: String, basis: QuestionBasis) {
        self.text = text
        self.answer = answer
        self.basis = basis
    }
}

public enum DecisionKind: String, Codable, CaseIterable, Sendable {
    case question
    case approval
}

public enum DecisionOverturnEffect: String, Codable, CaseIterable, Sendable {
    case stopped
    case recordedOnly = "recorded_only"
    case answerWithdrawn = "answer_withdrawn"
}

/// One orchestrator decision in Decided for you.
public struct Decision: Codable, Equatable, Sendable {
    public let questionID: UUID?
    public let actionID: UUID?
    public let decidedAt: Date
    public let undoable: Bool
    public let kind: DecisionKind
    public let taskID: UUID
    public let taskTitle: String
    public let seatID: UUID
    public let summary: String
    public let outcome: String?
    public let actionState: ActionState?
    public let started: Bool
    public let overturnedAt: Date?
    public let overturnEffect: DecisionOverturnEffect?

    public init(
        questionID: UUID? = nil, actionID: UUID? = nil, decidedAt: Date, undoable: Bool, kind: DecisionKind,
        taskID: UUID, taskTitle: String, seatID: UUID, summary: String, outcome: String? = nil,
        actionState: ActionState? = nil, started: Bool = false, overturnedAt: Date? = nil,
        overturnEffect: DecisionOverturnEffect? = nil
    ) {
        self.questionID = questionID
        self.actionID = actionID
        self.decidedAt = decidedAt
        self.undoable = undoable
        self.kind = kind
        self.taskID = taskID
        self.taskTitle = taskTitle
        self.seatID = seatID
        self.summary = summary
        self.outcome = outcome
        self.actionState = actionState
        self.started = started
        self.overturnedAt = overturnedAt
        self.overturnEffect = overturnEffect
    }

    enum CodingKeys: String, CodingKey {
        case undoable, kind, summary, outcome, started
        case questionID = "question_id"
        case actionID = "action_id"
        case decidedAt = "decided_at"
        case taskID = "task_id"
        case taskTitle = "task_title"
        case seatID = "seat_id"
        case actionState = "action_state"
        case overturnedAt = "overturned_at"
        case overturnEffect = "overturn_effect"
    }
}

public struct DecisionsList: Codable, Equatable, Sendable {
    public let decisions: [Decision]

    public init(decisions: [Decision]) {
        self.decisions = decisions
    }
}

public enum ProjectPauseReason: String, Codable, CaseIterable, Sendable {
    case owner
    case budget
}

/// A project, including its current brief in the owner's order.
public struct Project: Codable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let goal: String
    public let latestWorkReference: String?
    public let budget: Decimal?
    public let spent: Decimal
    public let paused: Bool
    public let briefVersion: Int
    public let brief: [BriefEntry]
    public let pausedBy: ProjectPauseReason?
    public let openTasks: Int
    public let contentDeletedAt: Date?

    public init(
        id: UUID, name: String, goal: String, budget: Decimal? = nil, spent: Decimal = 0,
        paused: Bool = false, briefVersion: Int, brief: [BriefEntry] = [], pausedBy: ProjectPauseReason? = nil,
        openTasks: Int = 0, contentDeletedAt: Date? = nil, latestWorkReference: String? = nil
    ) {
        self.id = id
        self.name = name
        self.goal = goal
        self.latestWorkReference = latestWorkReference
        self.budget = budget
        self.spent = spent
        self.paused = paused
        self.briefVersion = briefVersion
        self.brief = brief
        self.pausedBy = pausedBy
        self.openTasks = openTasks
        self.contentDeletedAt = contentDeletedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, name, goal, budget, spent, paused, brief
        case latestWorkReference = "latest_work_reference"
        case briefVersion = "brief_version"
        case pausedBy = "paused_by"
        case openTasks = "open_tasks"
        case contentDeletedAt = "content_deleted_at"
    }
}

public struct ProjectsList: Codable, Equatable, Sendable {
    public let projects: [Project]

    public init(projects: [Project]) {
        self.projects = projects
    }
}

/// The settings returned by the read and the update.
public struct WorkspaceSettings: Codable, Equatable, Sendable {
    public let leaseLengthSeconds: Int
    public let checkQueueTimeoutSeconds: Int
    public let checkRunTimeoutSeconds: Int
    public let maximumRounds: Int
    public let rerunLimit: Int
    public let recoveryTimeCeilingSeconds: Int?

    public init(
        leaseLengthSeconds: Int, checkQueueTimeoutSeconds: Int, checkRunTimeoutSeconds: Int,
        maximumRounds: Int, rerunLimit: Int, recoveryTimeCeilingSeconds: Int? = nil
    ) {
        self.leaseLengthSeconds = leaseLengthSeconds
        self.checkQueueTimeoutSeconds = checkQueueTimeoutSeconds
        self.checkRunTimeoutSeconds = checkRunTimeoutSeconds
        self.maximumRounds = maximumRounds
        self.rerunLimit = rerunLimit
        self.recoveryTimeCeilingSeconds = recoveryTimeCeilingSeconds
    }

    enum CodingKeys: String, CodingKey {
        case leaseLengthSeconds = "lease_length_seconds"
        case checkQueueTimeoutSeconds = "check_queue_timeout_seconds"
        case checkRunTimeoutSeconds = "check_run_timeout_seconds"
        case maximumRounds = "maximum_rounds"
        case rerunLimit = "rerun_limit"
        case recoveryTimeCeilingSeconds = "recovery_time_ceiling_seconds"
    }
}

/// Changes only the supplied settings. Clearing the recovery ceiling sends null.
public struct ChangeWorkspaceSettingsRequest: Encodable, Equatable, Sendable {
    public var leaseLengthSeconds: Int?
    public var checkQueueTimeoutSeconds: Int?
    public var checkRunTimeoutSeconds: Int?
    public var maximumRounds: Int?
    public var rerunLimit: Int?
    public var recoveryTimeCeilingSeconds: Setting<Int>

    public init(
        leaseLengthSeconds: Int? = nil, checkQueueTimeoutSeconds: Int? = nil, checkRunTimeoutSeconds: Int? = nil,
        maximumRounds: Int? = nil, rerunLimit: Int? = nil, recoveryTimeCeilingSeconds: Setting<Int> = .keep
    ) {
        self.leaseLengthSeconds = leaseLengthSeconds
        self.checkQueueTimeoutSeconds = checkQueueTimeoutSeconds
        self.checkRunTimeoutSeconds = checkRunTimeoutSeconds
        self.maximumRounds = maximumRounds
        self.rerunLimit = rerunLimit
        self.recoveryTimeCeilingSeconds = recoveryTimeCeilingSeconds
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: WorkspaceSettings.CodingKeys.self)
        try container.encodeIfPresent(leaseLengthSeconds, forKey: .leaseLengthSeconds)
        try container.encodeIfPresent(checkQueueTimeoutSeconds, forKey: .checkQueueTimeoutSeconds)
        try container.encodeIfPresent(checkRunTimeoutSeconds, forKey: .checkRunTimeoutSeconds)
        try container.encodeIfPresent(maximumRounds, forKey: .maximumRounds)
        try container.encodeIfPresent(rerunLimit, forKey: .rerunLimit)
        try recoveryTimeCeilingSeconds.write(to: &container, forKey: .recoveryTimeCeilingSeconds)
    }
}
