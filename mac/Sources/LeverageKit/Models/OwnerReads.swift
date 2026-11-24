import Foundation

// The owner's reads. Each provisional read carries `as_of_seq`, the log
// position of what it returns (MA-20).

/// `SetupState`: whether an owner exists yet (IN-2).
public struct SetupState: Codable, Equatable, Sendable {
    public let ownerExists: Bool

    public init(ownerExists: Bool) {
        self.ownerExists = ownerExists
    }

    enum CodingKeys: String, CodingKey {
        case ownerExists = "owner_exists"
    }
}

/// `BoardTask`: one card of the board.
public struct BoardTask: Codable, Equatable, Sendable {
    public let task: TaskSummary
    public let blocked: Bool
    public let holdReasons: [HoldReason]
    public let waitingForCredentialID: UUID?
    public let waitingUntil: Date?
    /// The task's open Needs you item, if any (MA-29).
    public let inboxItem: InboxItem?
    /// A transition of the task is pending and no hold is open (RD-27).
    public let checking: Bool
    /// The reason of the failed check behind an open `contract_incomplete`
    /// hold, or nil (RD-27). Text a model wrote: shown as data.
    public let checkReason: String?
    public let waitsForBuilder: Bool
    public let waitsForStrongerAgent: Bool

    public init(
        task: TaskSummary, blocked: Bool = false, holdReasons: [HoldReason] = [],
        waitingForCredentialID: UUID? = nil, waitingUntil: Date? = nil, inboxItem: InboxItem? = nil,
        checking: Bool = false, checkReason: String? = nil,
        waitsForBuilder: Bool = false, waitsForStrongerAgent: Bool = false
    ) {
        self.task = task
        self.blocked = blocked
        self.holdReasons = holdReasons
        self.waitingForCredentialID = waitingForCredentialID
        self.waitingUntil = waitingUntil
        self.inboxItem = inboxItem
        self.checking = checking
        self.checkReason = checkReason
        self.waitsForBuilder = waitsForBuilder
        self.waitsForStrongerAgent = waitsForStrongerAgent
    }

    enum CodingKeys: String, CodingKey {
        case task, blocked, checking
        case holdReasons = "hold_reasons"
        case waitingForCredentialID = "waiting_for_credential_id"
        case waitingUntil = "waiting_until"
        case inboxItem = "inbox_item"
        case checkReason = "check_reason"
        case waitsForBuilder = "waits_for_builder"
        case waitsForStrongerAgent = "waits_for_stronger_agent"
    }
}

/// `Board`: `GET /v1/owner/board`.
public struct Board: Codable, Equatable, Sendable {
    public let tasks: [BoardTask]
    public let asOfSeq: Int
    /// Whether any reviewer seat exists (SC-11).
    public let reviewerSeatExists: Bool

    public init(tasks: [BoardTask], asOfSeq: Int, reviewerSeatExists: Bool) {
        self.tasks = tasks
        self.asOfSeq = asOfSeq
        self.reviewerSeatExists = reviewerSeatExists
    }

    enum CodingKeys: String, CodingKey {
        case tasks
        case asOfSeq = "as_of_seq"
        case reviewerSeatExists = "reviewer_seat_exists"
    }
}

/// `LogName`: a name a task's log shows for a seat or a credential.
public struct LogName: Codable, Equatable, Sendable {
    public let kind: LogNameKind
    public let id: UUID
    public let name: String

    public init(kind: LogNameKind, id: UUID, name: String) {
        self.kind = kind
        self.id = id
        self.name = name
    }
}

/// `Event`: one event of the log.
public struct EventRecord: Codable, Equatable, Sendable {
    public let id: UUID
    public let workspaceID: UUID
    public let seq: Int
    public let at: Date
    public let effectiveAt: Date
    public let type: EventType
    public let schemaVersion: Int
    public let actorKind: ActorKind
    public let actorID: UUID?
    public let projectID: UUID?
    public let taskID: UUID?
    public let round: Int?
    public let subjectKind: EventSubjectKind?
    public let subjectID: UUID?
    public let causeID: UUID?
    public let commandID: String?
    public let payload: [String: JSONValue]

    public init(
        id: UUID, workspaceID: UUID, seq: Int, at: Date, effectiveAt: Date? = nil, type: EventType,
        schemaVersion: Int = 1, actorKind: ActorKind, actorID: UUID? = nil, projectID: UUID? = nil,
        taskID: UUID? = nil, round: Int? = nil, subjectKind: EventSubjectKind? = nil, subjectID: UUID? = nil,
        causeID: UUID? = nil, commandID: String? = nil, payload: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.seq = seq
        self.at = at
        self.effectiveAt = effectiveAt ?? at
        self.type = type
        self.schemaVersion = schemaVersion
        self.actorKind = actorKind
        self.actorID = actorID
        self.projectID = projectID
        self.taskID = taskID
        self.round = round
        self.subjectKind = subjectKind
        self.subjectID = subjectID
        self.causeID = causeID
        self.commandID = commandID
        self.payload = payload
    }

    enum CodingKeys: String, CodingKey {
        case id, seq, at, type, round, payload
        case workspaceID = "workspace_id"
        case effectiveAt = "effective_at"
        case schemaVersion = "schema_version"
        case actorKind = "actor_kind"
        case actorID = "actor_id"
        case projectID = "project_id"
        case taskID = "task_id"
        case subjectKind = "subject_kind"
        case subjectID = "subject_id"
        case causeID = "cause_id"
        case commandID = "command_id"
    }
}

/// `EventsPage`: `GET /v1/owner/events`.
public struct EventsPage: Codable, Equatable, Sendable {
    public let events: [EventRecord]
    /// The `after_seq` to ask with next.
    public let nextAfterSeq: Int

    public init(events: [EventRecord], nextAfterSeq: Int) {
        self.events = events
        self.nextAfterSeq = nextAfterSeq
    }

    enum CodingKeys: String, CodingKey {
        case events
        case nextAfterSeq = "next_after_seq"
    }
}

/// `TaskPage`: `GET /v1/owner/tasks/{id}`, with the task's events and the
/// names its log needs (IN-35).
public struct TaskPage: Codable, Equatable, Sendable {
    public let task: TaskSummary
    public let criteria: [Criterion]
    public let actions: [Action]
    public let questions: [Question]
    public let holds: [Hold]
    public let reviews: [Review]
    public let inboxItems: [InboxItem]
    public let events: [EventRecord]
    public let names: [LogName]
    public let reviewerSeatExists: Bool
    public let asOfSeq: Int
    /// The task's recovery times, oldest start first (HE-17, HE-18).
    public let recoveryTimes: [RecoveryTime]
    /// The account the task waits for, as its board card names it, from
    /// the same reading (HM-40, HE-15, HE-16).
    public let waitingForCredentialID: UUID?
    /// When that account resets, as its board card says.
    public let waitingUntil: Date?
    /// The task's steps in order, from `task_steps` (RD-24).
    public let steps: [TaskStepRow]
    /// The task's lifetime to `asOf`: the sum of its steps' seconds.
    public let lifetimeSeconds: Double
    /// The database time the open step and the lifetime are measured to.
    public let asOf: Date
    /// The task's rule checks in order of creation (RD-28).
    public let ruleChecks: [RuleCheckRow]
    /// The waiting command and what it waits on, or nil.
    public let pending: PendingState?
    /// Where a contract draft stands (RD-37).
    public let draft: DraftState
    public let anyActionStarted: Bool

    public init(
        task: TaskSummary, criteria: [Criterion] = [], actions: [Action] = [], questions: [Question] = [],
        holds: [Hold] = [], waitingForCredentialID: UUID? = nil, waitingUntil: Date? = nil, reviews: [Review] = [],
        inboxItems: [InboxItem] = [], events: [EventRecord] = [], names: [LogName] = [],
        recoveryTimes: [RecoveryTime] = [], reviewerSeatExists: Bool, asOfSeq: Int,
        steps: [TaskStepRow] = [], lifetimeSeconds: Double = 0, asOf: Date = Date(timeIntervalSince1970: 0),
        ruleChecks: [RuleCheckRow] = [], pending: PendingState? = nil, draft: DraftState = .none,
        anyActionStarted: Bool = false
    ) {
        self.task = task
        self.criteria = criteria
        self.actions = actions
        self.questions = questions
        self.holds = holds
        self.waitingForCredentialID = waitingForCredentialID
        self.waitingUntil = waitingUntil
        self.reviews = reviews
        self.inboxItems = inboxItems
        self.events = events
        self.names = names
        self.recoveryTimes = recoveryTimes
        self.reviewerSeatExists = reviewerSeatExists
        self.asOfSeq = asOfSeq
        self.steps = steps
        self.lifetimeSeconds = lifetimeSeconds
        self.asOf = asOf
        self.ruleChecks = ruleChecks
        self.pending = pending
        self.draft = draft
        self.anyActionStarted = anyActionStarted
    }

    enum CodingKeys: String, CodingKey {
        case task, criteria, actions, questions, holds, reviews, events, names, steps, pending, draft
        case lifetimeSeconds = "lifetime_seconds"
        case asOf = "as_of"
        case ruleChecks = "rule_checks"
        case inboxItems = "inbox_items"
        case waitingForCredentialID = "waiting_for_credential_id"
        case waitingUntil = "waiting_until"
        case recoveryTimes = "recovery_times"
        case anyActionStarted = "any_action_started"
        case reviewerSeatExists = "reviewer_seat_exists"
        case asOfSeq = "as_of_seq"
    }
}

/// `Seat`: one agent seat.
public struct Seat: Codable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let provider: Provider
    public let model: String?
    public let effort: String?
    public let role: SeatRole
    public let strengthRank: Int?
    /// The login it runs on; nil for a seat that connects on its own.
    public let credentialID: UUID?
    public let enabled: Bool
    public let paused: Bool
    public let lastPolledAt: Date?
    public let runState: SeatRunState?
    public let removedAt: Date?
    public let wantedRunning: Bool
    /// The login the seat's current run is on: the one its seat token was
    /// issued for. Nil when the seat has no run (HD-3).
    public let runCredentialID: UUID?
    /// Why the seat's last run ended; nil when no run has ended (HD-3).
    public let runStopReason: RunStopReason?

    public init(
        id: UUID, name: String, provider: Provider, model: String? = nil, effort: String? = nil, role: SeatRole,
        strengthRank: Int? = nil, credentialID: UUID? = nil, enabled: Bool = true, paused: Bool = false,
        lastPolledAt: Date? = nil, runState: SeatRunState? = nil, removedAt: Date? = nil, wantedRunning: Bool = false,
        runCredentialID: UUID? = nil, runStopReason: RunStopReason? = nil
    ) {
        self.id = id
        self.name = name
        self.provider = provider
        self.model = model
        self.effort = effort
        self.role = role
        self.strengthRank = strengthRank
        self.credentialID = credentialID
        self.enabled = enabled
        self.paused = paused
        self.lastPolledAt = lastPolledAt
        self.runState = runState
        self.removedAt = removedAt
        self.wantedRunning = wantedRunning
        self.runCredentialID = runCredentialID
        self.runStopReason = runStopReason
    }

    enum CodingKeys: String, CodingKey {
        case id, name, provider, model, effort, role, enabled, paused
        case strengthRank = "strength_rank"
        case credentialID = "credential_id"
        case lastPolledAt = "last_polled_at"
        case runState = "run_state"
        case removedAt = "removed_at"
        case wantedRunning = "wanted_running"
        case runCredentialID = "run_credential_id"
        case runStopReason = "run_stop_reason"
    }
}

/// `SeatsList`: `GET /v1/owner/seats`.
public struct SeatsList: Codable, Equatable, Sendable {
    public let seats: [Seat]
    public let asOfSeq: Int

    public init(seats: [Seat], asOfSeq: Int) {
        self.seats = seats
        self.asOfSeq = asOfSeq
    }

    enum CodingKeys: String, CodingKey {
        case seats
        case asOfSeq = "as_of_seq"
    }
}

/// `SystemHealth`: `GET /v1/owner/health` (IN-33).
public struct SystemHealth: Codable, Equatable, Sendable {
    public let sweepLastRanAt: Date?
    /// More than 120 seconds since the sweep last ran.
    public let sweepLate: Bool
    public let helperLastReportedAt: Date?
    public let queuedHelperRequests: Int
    public let readyTasks: Int
    public let waitingReviews: Int
    public let orchestrator: OrchestratorState
    /// When the newest backup was made; nil when none was (HB-4).
    public let backupLastRanAt: Date?
    /// True when the newest backup is more than 26 hours old, or when there
    /// is none and the workspace is more than an hour old (HB-4).
    public let backupLate: Bool
    /// Rule checks queued and not claimed, plus those held with
    /// `check_error`, counted at each read (RD-18).
    public let waitingChecks: Int

    public init(
        sweepLastRanAt: Date?, sweepLate: Bool, helperLastReportedAt: Date?, queuedHelperRequests: Int,
        readyTasks: Int, waitingReviews: Int, orchestrator: OrchestratorState = .notSetUp,
        backupLastRanAt: Date? = nil, backupLate: Bool = false, waitingChecks: Int = 0
    ) {
        self.sweepLastRanAt = sweepLastRanAt
        self.sweepLate = sweepLate
        self.helperLastReportedAt = helperLastReportedAt
        self.queuedHelperRequests = queuedHelperRequests
        self.readyTasks = readyTasks
        self.waitingReviews = waitingReviews
        self.orchestrator = orchestrator
        self.backupLastRanAt = backupLastRanAt
        self.backupLate = backupLate
        self.waitingChecks = waitingChecks
    }

    enum CodingKeys: String, CodingKey {
        case orchestrator
        case sweepLastRanAt = "sweep_last_ran_at"
        case sweepLate = "sweep_late"
        case helperLastReportedAt = "helper_last_reported_at"
        case queuedHelperRequests = "queued_helper_requests"
        case readyTasks = "ready_tasks"
        case waitingReviews = "waiting_reviews"
        case backupLastRanAt = "backup_last_ran_at"
        case backupLate = "backup_late"
        case waitingChecks = "waiting_checks"
    }
}

public enum LandingPromptConnection: String, Codable, CaseIterable, Sendable {
    case http
    case mcp
}

/// `JoinInstructions`: what an authenticated seat reads when it joins.
public struct JoinInstructions: Codable, Equatable, Sendable {
    public let text: String
    public let role: SeatRole
    public let connection: LandingPromptConnection

    public init(text: String, role: SeatRole, connection: LandingPromptConnection) {
        self.text = text
        self.role = role
        self.connection = connection
    }
}

/// `TaskCreatedResult`: what Add task returns.
public struct TaskCreatedResult: Codable, Equatable, Sendable {
    public let taskID: UUID

    public init(taskID: UUID) {
        self.taskID = taskID
    }

    enum CodingKeys: String, CodingKey {
        case taskID = "task_id"
    }
}
