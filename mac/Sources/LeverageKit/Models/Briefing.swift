import Foundation

/// `BriefingVersions`: what a briefing was built from.
public struct BriefingVersions: Codable, Equatable, Sendable {
    public let ruleVersionIDs: [UUID]
    public let briefVersion: Int
    public let roleFileVersion: String
    public let contractVersion: Int

    public init(ruleVersionIDs: [UUID] = [], briefVersion: Int = 0, roleFileVersion: String, contractVersion: Int) {
        self.ruleVersionIDs = ruleVersionIDs
        self.briefVersion = briefVersion
        self.roleFileVersion = roleFileVersion
        self.contractVersion = contractVersion
    }

    enum CodingKeys: String, CodingKey {
        case ruleVersionIDs = "rule_version_ids"
        case briefVersion = "brief_version"
        case roleFileVersion = "role_file_version"
        case contractVersion = "contract_version"
    }
}

/// `BriefingRule`: a rule the briefing carries.
public struct BriefingRule: Codable, Equatable, Sendable {
    public let ruleID: UUID
    public let ruleVersionID: UUID
    public let key: String
    public let name: String
    public let instruction: String?
    public let mayApply: Bool

    public init(ruleID: UUID, ruleVersionID: UUID, key: String, name: String, instruction: String?, mayApply: Bool) {
        self.ruleID = ruleID
        self.ruleVersionID = ruleVersionID
        self.key = key
        self.name = name
        self.instruction = instruction
        self.mayApply = mayApply
    }

    enum CodingKeys: String, CodingKey {
        case key, name, instruction
        case ruleID = "rule_id"
        case ruleVersionID = "rule_version_id"
        case mayApply = "may_apply"
    }
}

/// `BriefEntry`: one entry of a project's brief.
public struct BriefEntry: Codable, Equatable, Sendable {
    public let id: UUID
    public let projectID: UUID
    public let kind: BriefEntryKind
    public let text: String
    public let authorKind: ActorKind
    public let authorID: UUID?

    public init(id: UUID, projectID: UUID, kind: BriefEntryKind, text: String, authorKind: ActorKind, authorID: UUID?) {
        self.id = id
        self.projectID = projectID
        self.kind = kind
        self.text = text
        self.authorKind = authorKind
        self.authorID = authorID
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, text
        case projectID = "project_id"
        case authorKind = "author_kind"
        case authorID = "author_id"
    }
}

/// `BriefingContract`: the task's contract as the briefing gives it.
public struct BriefingContract: Codable, Equatable, Sendable {
    public let contractVersion: Int
    public let goal: String
    public let details: String?
    public let criteria: [Criterion]
    public let actions: [Action]

    public init(contractVersion: Int, goal: String, details: String?, criteria: [Criterion], actions: [Action] = []) {
        self.contractVersion = contractVersion
        self.goal = goal
        self.details = details
        self.criteria = criteria
        self.actions = actions
    }

    enum CodingKeys: String, CodingKey {
        case goal, details, criteria, actions
        case contractVersion = "contract_version"
    }
}

/// `Briefing`: what a seat reads and acknowledges before it works.
public struct Briefing: Codable, Equatable, Sendable {
    public let hash: String
    public let versions: BriefingVersions
    public let rules: [BriefingRule]
    public let brief: [BriefEntry]
    public let roleFile: String
    public let contract: BriefingContract
    /// The task's answers. They do not change the briefing hash.
    public let answers: [AnsweredQuestion]

    public init(
        hash: String, versions: BriefingVersions, rules: [BriefingRule] = [], brief: [BriefEntry] = [],
        roleFile: String, contract: BriefingContract, answers: [AnsweredQuestion] = []
    ) {
        self.hash = hash
        self.versions = versions
        self.rules = rules
        self.brief = brief
        self.roleFile = roleFile
        self.contract = contract
        self.answers = answers
    }

    enum CodingKeys: String, CodingKey {
        case hash, versions, rules, brief, contract, answers
        case roleFile = "role_file"
    }
}

/// `BriefingResponse`: `GET /v1/tasks/{id}/briefing` and the review's.
public struct BriefingResponse: Codable, Equatable, Sendable {
    public let briefing: Briefing
    public let workReference: String?
    /// The notes of the failed reviews of earlier rounds, for the builder.
    public let reviewNotes: [ReviewNote]

    public init(briefing: Briefing, workReference: String?, reviewNotes: [ReviewNote] = []) {
        self.briefing = briefing
        self.workReference = workReference
        self.reviewNotes = reviewNotes
    }

    enum CodingKeys: String, CodingKey {
        case briefing
        case workReference = "work_reference"
        case reviewNotes = "review_notes"
    }
}
