import Foundation

/// A Prompt seat's report of the model and effort it knows it is using.
public struct ReportModelRequest: Encodable, Equatable, Sendable {
    public let model: String?
    public let effort: String?

    public init(model: String?, effort: String?) {
        self.model = model
        self.effort = effort
    }

    enum CodingKeys: String, CodingKey { case model, effort }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(model, forKey: .model)
        try container.encode(effort, forKey: .effort)
    }
}

/// The model and effort as stored, with an empty string for a null report.
public struct ReportedModel: Codable, Equatable, Sendable {
    public let model: String
    public let effort: String

    public init(model: String, effort: String) {
        self.model = model
        self.effort = effort
    }
}

/// The contract an agent supplies when adding a task.
public struct CreateTaskRequest: Encodable, Equatable, Sendable {
    public let title: String
    public let details: String?
    public let criteria: [CriterionInput]
    public let projectID: UUID?
    public let priority: Priority?
    public let workReference: String?

    public init(
        title: String, details: String? = nil, criteria: [CriterionInput],
        projectID: UUID? = nil, priority: Priority? = nil, workReference: String? = nil
    ) {
        self.title = title
        self.details = details
        self.criteria = criteria
        self.projectID = projectID
        self.priority = priority
        self.workReference = workReference
    }

    enum CodingKeys: String, CodingKey {
        case title, details, criteria, priority
        case projectID = "project_id"
        case workReference = "work_reference"
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(details, forKey: .details)
        try container.encode(criteria, forKey: .criteria)
        try container.encodeIfPresent(projectID?.contractString, forKey: .projectID)
        try container.encodeIfPresent(priority, forKey: .priority)
        try container.encodeIfPresent(workReference, forKey: .workReference)
    }
}

/// Where an agent-added task stands after the contract check.
public struct AgentTaskCreated: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case ready, backlog
    }

    public let taskID: UUID
    public let state: State

    public init(taskID: UUID, state: State) {
        self.taskID = taskID
        self.state = state
    }

    enum CodingKeys: String, CodingKey {
        case taskID = "task_id"
        case state
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeID(taskID, forKey: .taskID)
        try container.encode(state, forKey: .state)
    }
}
