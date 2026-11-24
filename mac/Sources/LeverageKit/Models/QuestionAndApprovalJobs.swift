import Foundation

/// The task contract given to a question or approval job.
public struct ActionJobContract: Codable, Equatable, Sendable {
    public let title: String
    public let details: String?
    public let criteria: [CheckContract.Criterion]
    public let actions: [ActionInput]

    public init(
        title: String, details: String? = nil,
        criteria: [CheckContract.Criterion], actions: [ActionInput] = []
    ) {
        self.title = title
        self.details = details
        self.criteria = criteria
        self.actions = actions
    }
}

public struct QuestionMaterial: Codable, Equatable, Sendable {
    public let roleFile: String?
    public let jobRules: [String]
    public let question: AskQuestionRequest
    public let contract: ActionJobContract
    public let brief: [BriefEntry]
    public let earlierAnswers: [AnsweredQuestion]

    public init(
        roleFile: String?, jobRules: [String] = [], question: AskQuestionRequest, contract: ActionJobContract,
        brief: [BriefEntry] = [], earlierAnswers: [AnsweredQuestion] = []
    ) {
        self.roleFile = roleFile
        self.jobRules = jobRules
        self.question = question
        self.contract = contract
        self.brief = brief
        self.earlierAnswers = earlierAnswers
    }

    enum CodingKeys: String, CodingKey {
        case question, contract, brief
        case roleFile = "role_file"
        case jobRules = "job_rules"
        case earlierAnswers = "earlier_answers"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        roleFile = try container.decode(String?.self, forKey: .roleFile)
        jobRules = container.contains(.jobRules) ? try container.decode([String].self, forKey: .jobRules) : []
        question = try container.decode(AskQuestionRequest.self, forKey: .question)
        contract = try container.decode(ActionJobContract.self, forKey: .contract)
        brief = try container.decode([BriefEntry].self, forKey: .brief)
        earlierAnswers = try container.decode([AnsweredQuestion].self, forKey: .earlierAnswers)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(roleFile, forKey: .roleFile)
        try container.encode(jobRules, forKey: .jobRules)
        try container.encode(question, forKey: .question)
        try container.encode(contract, forKey: .contract)
        try container.encode(brief, forKey: .brief)
        try container.encode(earlierAnswers, forKey: .earlierAnswers)
    }
}

public struct QuestionJobInput: Codable, Equatable, Sendable {
    public let questionID: UUID
    public let taskID: UUID
    public let projectID: UUID?
    public let material: QuestionMaterial

    public init(questionID: UUID, taskID: UUID, projectID: UUID? = nil, material: QuestionMaterial) {
        self.questionID = questionID
        self.taskID = taskID
        self.projectID = projectID
        self.material = material
    }

    enum CodingKeys: String, CodingKey {
        case material
        case questionID = "question_id"
        case taskID = "task_id"
        case projectID = "project_id"
    }
}

public enum QuestionJobOutcome: String, Codable, CaseIterable, Sendable {
    case answered
    case passedOn = "passed_on"
}

public enum QuestionJobBasis: String, Codable, CaseIterable, Sendable {
    case record
    case decision
}

/// The orchestrator's answer or its decision to pass the question on.
public struct QuestionJobResult: Codable, Equatable, Sendable {
    public static let answerLimit = 4_000

    public let outcome: QuestionJobOutcome
    public let answer: String?
    public let basis: QuestionJobBasis?

    public init(outcome: QuestionJobOutcome, answer: String? = nil, basis: QuestionJobBasis? = nil) {
        self.outcome = outcome
        self.answer = answer
        self.basis = basis
    }

    enum CodingKeys: String, CodingKey {
        case outcome, answer, basis
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(outcome, forKey: .outcome)
        try container.encode(answer, forKey: .answer)
        try container.encode(basis, forKey: .basis)
    }
}

public struct ApprovalMaterial: Codable, Equatable, Sendable {
    public struct Action: Codable, Equatable, Sendable {
        public let kind: ActionKind
        public let description: String
        public let position: Int

        public init(kind: ActionKind, description: String, position: Int) {
            self.kind = kind
            self.description = description
            self.position = position
        }
    }

    public enum QuoteLabel: String, Codable, CaseIterable, Sendable {
        case handoffNote = "handoff_note"
        case reviewNotes = "review_notes"
        case evidence
    }

    public struct Quote: Codable, Equatable, Sendable {
        public let label: QuoteLabel
        public let text: String

        public init(label: QuoteLabel, text: String) {
            self.label = label
            self.text = text
        }
    }

    public let roleFile: String?
    public let jobRules: [String]
    public let instruction: String
    public let action: Action
    public let contract: ActionJobContract
    public let quoted: [Quote]

    public init(
        roleFile: String?, jobRules: [String] = [], instruction: String, action: Action, contract: ActionJobContract, quoted: [Quote] = []
    ) {
        self.roleFile = roleFile
        self.jobRules = jobRules
        self.instruction = instruction
        self.action = action
        self.contract = contract
        self.quoted = quoted
    }

    enum CodingKeys: String, CodingKey {
        case instruction, action, contract, quoted
        case roleFile = "role_file"
        case jobRules = "job_rules"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        roleFile = try container.decode(String?.self, forKey: .roleFile)
        jobRules = container.contains(.jobRules) ? try container.decode([String].self, forKey: .jobRules) : []
        instruction = try container.decode(String.self, forKey: .instruction)
        action = try container.decode(Action.self, forKey: .action)
        contract = try container.decode(ActionJobContract.self, forKey: .contract)
        quoted = try container.decode([Quote].self, forKey: .quoted)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(roleFile, forKey: .roleFile)
        try container.encode(jobRules, forKey: .jobRules)
        try container.encode(instruction, forKey: .instruction)
        try container.encode(action, forKey: .action)
        try container.encode(contract, forKey: .contract)
        try container.encode(quoted, forKey: .quoted)
    }
}

public struct ApprovalJobInput: Codable, Equatable, Sendable {
    public let actionID: UUID
    public let ruleCheckID: UUID
    public let taskID: UUID
    public let projectID: UUID?
    public let material: ApprovalMaterial

    public init(actionID: UUID, ruleCheckID: UUID, taskID: UUID, projectID: UUID? = nil, material: ApprovalMaterial) {
        self.actionID = actionID
        self.ruleCheckID = ruleCheckID
        self.taskID = taskID
        self.projectID = projectID
        self.material = material
    }

    enum CodingKeys: String, CodingKey {
        case material
        case actionID = "action_id"
        case ruleCheckID = "rule_check_id"
        case taskID = "task_id"
        case projectID = "project_id"
    }
}

public enum ApprovalDecision: String, Codable, CaseIterable, Sendable {
    case approve
    case stop
    case passToOwner = "pass_to_owner"
}

public struct ApprovalJobResult: Codable, Equatable, Sendable {
    public static let reasonLimit = 500

    public let decision: ApprovalDecision
    public let reason: String

    public init(decision: ApprovalDecision, reason: String) {
        self.decision = decision
        self.reason = reason
    }
}
