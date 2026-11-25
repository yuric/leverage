import Foundation

// What an orchestrator or a planner is given and sends back (milestone 4
// plan sections 2.2 and 2.3). A job's seat has no read call: everything it
// needs is in the claim's `material` (RD-30).

/// `CheckContract`: the contract a check judges. At `task.before_ready` it
/// is the requested one, else the task's current one (RD-30, RE-2). The
/// runner quotes it under the label `contract`.
public struct CheckContract: Codable, Equatable, Sendable {
    public struct Criterion: Codable, Equatable, Sendable {
        public let text: String
        public let kind: CriterionKind
        public let state: CriterionState

        public init(text: String, kind: CriterionKind, state: CriterionState = .open) {
            self.text = text
            self.kind = kind
            self.state = state
        }
    }

    public let title: String
    public let details: String?
    public let criteria: [Criterion]

    public init(title: String, details: String? = nil, criteria: [Criterion]) {
        self.title = title
        self.details = details
        self.criteria = criteria
    }
}

/// `QuotedText`: one piece of task text a checker is given as material,
/// never as an instruction (L429, RD-31).
public struct QuotedText: Codable, Equatable, Sendable {
    public let label: QuotedLabel
    public let text: String

    public init(label: QuotedLabel, text: String) {
        self.label = label
        self.text = text
    }
}

/// `CheckMaterial`: everything a checker needs, built when the job is
/// claimed from the frozen rule version and the task's rows or the pending
/// request, never stored in an event (RD-30).
public struct CheckMaterial: Codable, Equatable, Sendable {
    /// The orchestrator's role file, absent for a General seat.
    public let roleFile: String?
    public let jobRules: [String]
    /// The frozen rule version's instruction.
    public let instruction: String
    /// The hook's moment name (`RuleHook.momentName`).
    public let moment: String
    /// True only for a "let the checker decide" rule.
    public let mayAnswerNotApplicable: Bool
    public let contract: CheckContract
    /// The other task text the hook's inputs hold, each under its label.
    public let quoted: [QuotedText]

    public init(
        roleFile: String?, jobRules: [String] = [], instruction: String, moment: String, mayAnswerNotApplicable: Bool = false,
        contract: CheckContract, quoted: [QuotedText] = []
    ) {
        self.roleFile = roleFile
        self.jobRules = jobRules
        self.instruction = instruction
        self.moment = moment
        self.mayAnswerNotApplicable = mayAnswerNotApplicable
        self.contract = contract
        self.quoted = quoted
    }

    enum CodingKeys: String, CodingKey {
        case instruction, moment, contract, quoted
        case roleFile = "role_file"
        case jobRules = "job_rules"
        case mayAnswerNotApplicable = "may_answer_not_applicable"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        roleFile = try container.decode(String?.self, forKey: .roleFile)
        jobRules = container.contains(.jobRules) ? try container.decode([String].self, forKey: .jobRules) : []
        instruction = try container.decode(String.self, forKey: .instruction)
        moment = try container.decode(String.self, forKey: .moment)
        mayAnswerNotApplicable = try container.decode(Bool.self, forKey: .mayAnswerNotApplicable)
        contract = try container.decode(CheckContract.self, forKey: .contract)
        quoted = try container.decode([QuotedText].self, forKey: .quoted)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(roleFile, forKey: .roleFile)
        try container.encode(jobRules, forKey: .jobRules)
        try container.encode(instruction, forKey: .instruction)
        try container.encode(moment, forKey: .moment)
        try container.encode(mayAnswerNotApplicable, forKey: .mayAnswerNotApplicable)
        try container.encode(contract, forKey: .contract)
        try container.encode(quoted, forKey: .quoted)
    }
}

/// `RuleCheckJobInput`: one rule-check job.
public struct RuleCheckJobInput: Codable, Equatable, Sendable {
    public let ruleCheckID: UUID
    public let attemptNumber: Int
    public let ruleVersionID: UUID
    public let hook: RuleHook
    public let taskID: UUID
    public let projectID: UUID?
    /// The hashed inputs of the hook.
    public let inputs: [String: JSONValue]
    public let material: CheckMaterial

    public init(
        ruleCheckID: UUID, attemptNumber: Int = 1, ruleVersionID: UUID, hook: RuleHook, taskID: UUID,
        projectID: UUID? = nil, inputs: [String: JSONValue] = [:], material: CheckMaterial
    ) {
        self.ruleCheckID = ruleCheckID
        self.attemptNumber = attemptNumber
        self.ruleVersionID = ruleVersionID
        self.hook = hook
        self.taskID = taskID
        self.projectID = projectID
        self.inputs = inputs
        self.material = material
    }

    enum CodingKeys: String, CodingKey {
        case hook, inputs, material
        case ruleCheckID = "rule_check_id"
        case attemptNumber = "attempt_number"
        case ruleVersionID = "rule_version_id"
        case taskID = "task_id"
        case projectID = "project_id"
    }
}

/// `DraftMaterial`: everything a planner needs (RD-30, RD-37): the task's
/// text, the criteria it already has, which the planner keeps, and the three
/// stored values the result sends back unchanged. The server keeps the
/// stored ones, and the task's outward actions, whatever the result holds.
public struct DraftMaterial: Codable, Equatable, Sendable {
    /// The planner's role file, absent for a General seat.
    public let roleFile: String?
    public let jobRules: [String]
    public let title: String
    public let details: String?
    /// The criteria the task already has, which may be none.
    public let criteria: [CriterionInput]
    public let workReference: String?
    public let minimumStrengthRank: Int?
    public let budgetCap: Decimal?
    /// The project's brief; empty while tasks have no project.
    public let brief: [BriefEntry]

    public init(
        roleFile: String?, jobRules: [String] = [], title: String, details: String? = nil, criteria: [CriterionInput] = [],
        workReference: String? = nil, minimumStrengthRank: Int? = nil, budgetCap: Decimal? = nil,
        brief: [BriefEntry] = []
    ) {
        self.roleFile = roleFile
        self.jobRules = jobRules
        self.title = title
        self.details = details
        self.criteria = criteria
        self.workReference = workReference
        self.minimumStrengthRank = minimumStrengthRank
        self.budgetCap = budgetCap
        self.brief = brief
    }

    enum CodingKeys: String, CodingKey {
        case title, details, criteria, brief
        case roleFile = "role_file"
        case jobRules = "job_rules"
        case workReference = "work_reference"
        case minimumStrengthRank = "minimum_strength_rank"
        case budgetCap = "budget_cap"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        roleFile = try container.decode(String?.self, forKey: .roleFile)
        jobRules = container.contains(.jobRules) ? try container.decode([String].self, forKey: .jobRules) : []
        title = try container.decode(String.self, forKey: .title)
        details = try container.decodeIfPresent(String.self, forKey: .details)
        criteria = try container.decode([CriterionInput].self, forKey: .criteria)
        workReference = try container.decodeIfPresent(String.self, forKey: .workReference)
        minimumStrengthRank = try container.decodeIfPresent(Int.self, forKey: .minimumStrengthRank)
        budgetCap = try container.decodeIfPresent(Decimal.self, forKey: .budgetCap)
        brief = try container.decode([BriefEntry].self, forKey: .brief)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(roleFile, forKey: .roleFile)
        try container.encode(jobRules, forKey: .jobRules)
        try container.encode(title, forKey: .title)
        try container.encode(details, forKey: .details)
        try container.encode(criteria, forKey: .criteria)
        try container.encode(workReference, forKey: .workReference)
        try container.encode(minimumStrengthRank, forKey: .minimumStrengthRank)
        try container.encode(budgetCap, forKey: .budgetCap)
        try container.encode(brief, forKey: .brief)
    }
}

/// `ContractDraftJobInput`: one contract-draft job.
public struct ContractDraftJobInput: Codable, Equatable, Sendable {
    public let taskID: UUID
    public let projectID: UUID?
    public let briefVersion: Int
    public let material: DraftMaterial

    public init(taskID: UUID, projectID: UUID? = nil, briefVersion: Int = 0, material: DraftMaterial) {
        self.taskID = taskID
        self.projectID = projectID
        self.briefVersion = briefVersion
        self.material = material
    }

    enum CodingKeys: String, CodingKey {
        case material
        case taskID = "task_id"
        case projectID = "project_id"
        case briefVersion = "brief_version"
    }
}

/// A job's input, by its kind. Questions and approvals keep their wire
/// payload and expose typed material to the runner.
public enum JobInput: Equatable, Sendable {
    case ruleCheck(RuleCheckJobInput)
    case contractDraft(ContractDraftJobInput)
    case other(JobKind, JSONValue)

    public var questionInput: QuestionJobInput? {
        decodeInput(for: .question, as: QuestionJobInput.self)
    }

    public var approvalInput: ApprovalJobInput? {
        decodeInput(for: .approval, as: ApprovalJobInput.self)
    }

    private func decodeInput<Input: Decodable>(for kind: JobKind, as type: Input.Type) -> Input? {
        guard case .other(let actualKind, let payload) = self, actualKind == kind,
              let data = try? LeverageJSON.encoder().encode(payload) else {
            return nil
        }
        return try? LeverageJSON.decoder().decode(type, from: data)
    }
}

/// `ClaimJobResult`: the next job. Context is limited to the task's own
/// project.
public struct JobClaim: Codable, Equatable, Sendable {
    public let jobID: UUID
    public let kind: JobKind
    public let input: JobInput
    /// The credential the claim runs on; nil for a seat that connects on its
    /// own.
    public let credentialID: UUID?
    /// The model the claim runs with; nil when none is set.
    public let model: String?
    /// The time after which a result for this job is discarded and refused
    /// (L399). The reference runner ends its tool 10 seconds before it
    /// (RD-34).
    public let runDueAt: Date

    public init(
        jobID: UUID, kind: JobKind, input: JobInput, credentialID: UUID? = nil, model: String? = nil,
        runDueAt: Date
    ) {
        self.jobID = jobID
        self.kind = kind
        self.input = input
        self.credentialID = credentialID
        self.model = model
        self.runDueAt = runDueAt
    }

    enum CodingKeys: String, CodingKey {
        case kind, input, model
        case jobID = "job_id"
        case credentialID = "credential_id"
        case runDueAt = "run_due_at"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        jobID = try container.decode(UUID.self, forKey: .jobID)
        kind = try container.decode(JobKind.self, forKey: .kind)
        switch kind {
        case .ruleCheck: input = .ruleCheck(try container.decode(RuleCheckJobInput.self, forKey: .input))
        case .contractDraft: input = .contractDraft(try container.decode(ContractDraftJobInput.self, forKey: .input))
        case .question, .approval: input = .other(kind, try container.decode(JSONValue.self, forKey: .input))
        }
        credentialID = try container.decodeIfPresent(UUID.self, forKey: .credentialID)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        runDueAt = try container.decode(Date.self, forKey: .runDueAt)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(jobID, forKey: .jobID)
        try container.encode(kind, forKey: .kind)
        switch input {
        case .ruleCheck(let value): try container.encode(value, forKey: .input)
        case .contractDraft(let value): try container.encode(value, forKey: .input)
        case .other(_, let value): try container.encode(value, forKey: .input)
        }
        try container.encode(credentialID, forKey: .credentialID)
        try container.encode(model, forKey: .model)
        try container.encode(runDueAt, forKey: .runDueAt)
    }
}

/// `DraftContractResult`: what Draft the details answers: the planner job it
/// queued.
public struct DraftContractResult: Codable, Equatable, Sendable {
    public let jobID: UUID

    public init(jobID: UUID) {
        self.jobID = jobID
    }

    enum CodingKeys: String, CodingKey {
        case jobID = "job_id"
    }
}

/// `RuleCheckJobResult`: a checker's answer. `not_applicable` only for a
/// "let the checker decide" rule. The reason is free text from a model, at
/// most 500 characters (L428, RD-31); it is stored on the check row and
/// never in an event.
public struct RuleCheckVerdict: Codable, Equatable, Sendable {
    /// The longest reason the contract allows.
    public static let reasonLimit = 500

    public let result: CheckVerdict
    public let reason: String

    public init(result: CheckVerdict, reason: String) {
        self.result = result
        self.reason = reason
    }
}

/// What a job's result holds, by the job's kind. A contract draft's result
/// is the Complete contract command's body (RC-33).
public enum JobResult: Encodable, Equatable, Sendable {
    case ruleCheck(RuleCheckVerdict)
    case contractDraft(CompleteContractRequest)
    case question(QuestionJobResult)
    case approval(ApprovalJobResult)

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .ruleCheck(let verdict): try container.encode(verdict)
        case .contractDraft(let contract): try container.encode(contract)
        case .question(let answer): try container.encode(answer)
        case .approval(let decision): try container.encode(decision)
        }
    }
}

/// `JobResultRequest`: the result in the fixed shape for the job's kind,
/// with the tokens and spend it used (RD-32: tokens as the tool reported,
/// spend 0 for a login).
public struct JobResultRequest: Encodable, Equatable, Sendable {
    public let result: JobResult
    public let tokens: Int
    public let spend: Decimal

    public init(result: JobResult, tokens: Int = 0, spend: Decimal = 0) {
        self.result = result
        self.tokens = tokens
        self.spend = spend
    }

    enum CodingKeys: String, CodingKey {
        case result, tokens, spend
    }
}
