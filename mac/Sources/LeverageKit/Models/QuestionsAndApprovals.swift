public struct AnsweredQuestion: Codable, Equatable, Sendable {}
public struct AskQuestionResult: Codable, Equatable, Sendable {}
public struct Decision: Codable, Equatable, Sendable {}
public struct DecisionsList: Codable, Equatable, Sendable {}
public struct Project: Codable, Equatable, Sendable {}
public struct ProjectsList: Codable, Equatable, Sendable {}
public struct WorkspaceSettings: Codable, Equatable, Sendable {}
public struct QuestionMaterial: Codable, Equatable, Sendable {}
public struct ApprovalMaterial: Codable, Equatable, Sendable {}
public struct QuestionJobInput: Codable, Equatable, Sendable {}
public struct ApprovalJobInput: Codable, Equatable, Sendable {}
public struct QuestionJobResult: Codable, Equatable, Sendable {}
public struct ApprovalJobResult: Codable, Equatable, Sendable {}
public struct ChangeWorkspaceSettingsRequest: Encodable, Equatable, Sendable {
    public init(maximumRounds: Int? = nil, recoveryTimeCeilingSeconds: Setting<Int> = .keep) {}
}
public typealias OutwardAction = Action

extension JobInput {
    public var questionInput: QuestionJobInput? { nil }
    public var approvalInput: ApprovalJobInput? { nil }
}
