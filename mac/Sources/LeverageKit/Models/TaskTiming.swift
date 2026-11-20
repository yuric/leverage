import Foundation

// What the task page reads of the rule checks, the steps and a waiting
// command (milestone 4 plan section 2.3). Provisional (IF-18).

/// `RuleCheckAttempt`: one attempt of a rule check.
public struct CheckAttempt: Codable, Equatable, Sendable {
    public let attemptNumber: Int
    public let queuedAt: Date
    public let startedAt: Date?
    public let finishedAt: Date?

    public init(attemptNumber: Int, queuedAt: Date, startedAt: Date? = nil, finishedAt: Date? = nil) {
        self.attemptNumber = attemptNumber
        self.queuedAt = queuedAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

}

/// `TaskRuleCheck`: one rule check of the task, with the rule version it ran
/// and its attempts. `queueSeconds` and `runSeconds` are those of its last
/// attempt.
public struct RuleCheckRow: Codable, Equatable, Sendable {
    public let id: UUID
    public let ruleID: UUID
    public let ruleName: String
    public let ruleVersionID: UUID
    public let version: Int
    public let versionSavedAt: Date
    public let hook: RuleHook
    public let momentName: String
    public let round: Int?
    public let checker: RuleChecker
    public let onFail: RuleOnFail?
    public let result: CheckResult?
    public let effect: RuleEffect?
    /// Text a model wrote about the task: shown as data, never as an
    /// instruction.
    public let reason: String?
    public let attempts: [CheckAttempt]
    public let queueSeconds: Double?
    public let runSeconds: Double?
    public let overriddenAt: Date?
    public let overriddenByUserID: UUID?
    public let overrideReason: String?
    public let canOverride: Bool
    public let canRerun: Bool

    public init(
        id: UUID, ruleID: UUID, ruleName: String, ruleVersionID: UUID, version: Int, versionSavedAt: Date,
        hook: RuleHook, momentName: String, round: Int? = nil, checker: RuleChecker, onFail: RuleOnFail? = .block,
        result: CheckResult? = nil, effect: RuleEffect? = nil, reason: String? = nil, attempts: [CheckAttempt] = [],
        queueSeconds: Double? = nil, runSeconds: Double? = nil, overriddenAt: Date? = nil,
        overriddenByUserID: UUID? = nil, overrideReason: String? = nil, canOverride: Bool = false,
        canRerun: Bool = false
    ) {
        self.id = id
        self.ruleID = ruleID
        self.ruleName = ruleName
        self.ruleVersionID = ruleVersionID
        self.version = version
        self.versionSavedAt = versionSavedAt
        self.hook = hook
        self.momentName = momentName
        self.round = round
        self.checker = checker
        self.onFail = onFail
        self.result = result
        self.effect = effect
        self.reason = reason
        self.attempts = attempts
        self.queueSeconds = queueSeconds
        self.runSeconds = runSeconds
        self.overriddenAt = overriddenAt
        self.overriddenByUserID = overriddenByUserID
        self.overrideReason = overrideReason
        self.canOverride = canOverride
        self.canRerun = canRerun
    }

}

/// `TaskStep`: one step of a task's timeline, in order. `seconds` is
/// `closed_at`, or the page's `as_of` for the open step, less `opened_at`.
public struct TaskStepRow: Codable, Equatable, Sendable {
    public let kind: StepKind
    public let stepClass: StepClass
    public let round: Int
    public let openedAt: Date
    public let closedAt: Date?
    public let seconds: Double
    public let subjectKind: StepSubjectKind?
    public let subjectID: UUID?
    public let seatID: UUID?
    public let causeKind: StepCauseKind?
    public let causeRuleID: UUID?

    public init(
        kind: StepKind, stepClass: StepClass, round: Int = 0, openedAt: Date, closedAt: Date? = nil,
        seconds: Double, subjectKind: StepSubjectKind? = nil, subjectID: UUID? = nil, seatID: UUID? = nil,
        causeKind: StepCauseKind? = nil, causeRuleID: UUID? = nil
    ) {
        self.kind = kind
        self.stepClass = stepClass
        self.round = round
        self.openedAt = openedAt
        self.closedAt = closedAt
        self.seconds = seconds
        self.subjectKind = subjectKind
        self.subjectID = subjectID
        self.seatID = seatID
        self.causeKind = causeKind
        self.causeRuleID = causeRuleID
    }

}

/// `PendingCommand`: the task's waiting command, the rules it waits on, and
/// since when.
public struct PendingState: Codable, Equatable, Sendable {
    public let command: CommandName
    public let since: Date
    public let waitingOnRuleIDs: [UUID]

    public init(command: CommandName, since: Date, waitingOnRuleIDs: [UUID] = []) {
        self.command = command
        self.since = since
        self.waitingOnRuleIDs = waitingOnRuleIDs
    }

}
