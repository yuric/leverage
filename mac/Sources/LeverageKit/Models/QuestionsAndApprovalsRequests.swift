import Foundation

/// The question, including the assumption the worker can use while it waits.
public struct AskQuestionRequest: Codable, Equatable, Sendable {
    public let text: String
    public let assumption: String
    public let blocking: Bool

    public init(text: String, assumption: String, blocking: Bool) {
        self.text = text
        self.assumption = assumption
        self.blocking = blocking
    }
}

public struct RequestAccessRequest: Encodable, Equatable, Sendable {
    public let description: String

    public init(description: String) {
        self.description = description
    }
}

public struct ReportCostRequest: Encodable, Equatable, Sendable {
    public let tokens: Int
    public let spend: Decimal

    public init(tokens: Int, spend: Decimal) {
        self.tokens = tokens
        self.spend = spend
    }
}

public struct AnswerQuestionRequest: Encodable, Equatable, Sendable {
    public let answer: String

    public init(answer: String) {
        self.answer = answer
    }
}

public struct CreateProjectRequest: Encodable, Equatable, Sendable {
    public let name: String
    public let goal: String?
    public let budget: Decimal?

    public init(name: String, goal: String? = nil, budget: Decimal? = nil) {
        self.name = name
        self.goal = goal
        self.budget = budget
    }
}

public struct BriefEntryInput: Encodable, Equatable, Sendable {
    public let kind: BriefEntryKind
    public let text: String

    public init(kind: BriefEntryKind, text: String) {
        self.kind = kind
        self.text = text
    }
}

public struct EditBriefRequest: Encodable, Equatable, Sendable {
    public let entries: [BriefEntryInput]

    public init(entries: [BriefEntryInput]) {
        self.entries = entries
    }
}

public struct ChangeBudgetRequest: Encodable, Equatable, Sendable {
    public let budget: Decimal?

    public init(budget: Decimal?) {
        self.budget = budget
    }

    enum CodingKeys: String, CodingKey {
        case budget
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(budget, forKey: .budget)
    }
}

public struct ChangeTaskPriorityRequest: Encodable, Equatable, Sendable {
    public let priority: Priority

    public init(priority: Priority) {
        self.priority = priority
    }
}

public struct ChangeTaskProjectRequest: Encodable, Equatable, Sendable {
    public let projectID: UUID?

    public init(projectID: UUID?) {
        self.projectID = projectID
    }

    enum CodingKeys: String, CodingKey {
        case projectID = "project_id"
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeID(projectID, forKey: .projectID)
    }
}

public struct ChangeTaskCapRequest: Encodable, Equatable, Sendable {
    public let budgetCap: Decimal?

    public init(budgetCap: Decimal?) {
        self.budgetCap = budgetCap
    }

    enum CodingKeys: String, CodingKey {
        case budgetCap = "budget_cap"
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(budgetCap, forKey: .budgetCap)
    }
}

public struct ReturnForReworkRequest: Encodable, Equatable, Sendable {
    public let criterionIDs: [UUID]

    public init(criterionIDs: [UUID]) {
        self.criterionIDs = criterionIDs
    }

    enum CodingKeys: String, CodingKey {
        case criterionIDs = "criterion_ids"
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIDs(criterionIDs, forKey: .criterionIDs)
    }
}
