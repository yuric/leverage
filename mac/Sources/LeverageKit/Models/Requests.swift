import Foundation

// The bodies the Mac side sends. Each writes exactly the fields its schema
// has: a required field always (null where it is nullable and nil), an
// optional one only when set; ids in lower case.

/// `SignInRequest`: setup and sign-in. Printed without its password.
public struct SignInRequest: Encodable, Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable {
    public let emailAddress: String
    public let password: String

    public init(emailAddress: String, password: String) {
        self.emailAddress = emailAddress
        self.password = password
    }

    enum CodingKeys: String, CodingKey {
        case password
        case emailAddress = "email_address"
    }

    public var description: String { "SignInRequest(emailAddress: [removed], password: [removed])" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// `CriterionInput`: a criterion as the contract form sends it.
public struct CriterionInput: Encodable, Equatable, Sendable {
    public let text: String
    public let kind: CriterionKind

    public init(text: String, kind: CriterionKind = .build) {
        self.text = text
        self.kind = kind
    }
}

/// `ActionInput`: an outward action as the contract form sends it.
public struct ActionInput: Encodable, Equatable, Sendable {
    public let kind: ActionKind
    public let description: String

    public init(kind: ActionKind, description: String) {
        self.kind = kind
        self.description = description
    }
}

/// `AddTaskRequest`. Add task sends title, goal, priority, work reference
/// and the target state; the contract goes in Complete contract (IN-20).
public struct AddTaskRequest: Encodable, Equatable, Sendable {
    public let title: String
    public let goal: String
    public let details: String?
    public let criteria: [CriterionInput]?
    public let actions: [ActionInput]?
    public let projectID: UUID?
    public let priority: Priority?
    public let workReference: String?
    public let state: TaskState?

    public init(
        title: String, goal: String, details: String? = nil, criteria: [CriterionInput]? = nil,
        actions: [ActionInput]? = nil, projectID: UUID? = nil, priority: Priority? = nil,
        workReference: String? = nil, state: TaskState? = nil
    ) {
        self.title = title
        self.goal = goal
        self.details = details
        self.criteria = criteria
        self.actions = actions
        self.projectID = projectID
        self.priority = priority
        self.workReference = workReference
        self.state = state
    }

    enum CodingKeys: String, CodingKey {
        case title, goal, details, criteria, actions, priority, state
        case projectID = "project_id"
        case workReference = "work_reference"
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(title, forKey: .title)
        try container.encode(goal, forKey: .goal)
        try container.encodeIfPresent(details, forKey: .details)
        try container.encodeIfPresent(criteria, forKey: .criteria)
        try container.encodeIfPresent(actions, forKey: .actions)
        if let projectID { try container.encodeID(projectID, forKey: .projectID) }
        try container.encodeIfPresent(priority, forKey: .priority)
        try container.encodeIfPresent(workReference, forKey: .workReference)
        try container.encodeIfPresent(state, forKey: .state)
    }
}

/// `CompleteContractRequest`: every field, the form's values sent again
/// (IN-20).
public struct CompleteContractRequest: Encodable, Equatable, Sendable {
    public let title: String
    public let goal: String
    public let details: String?
    public let criteria: [CriterionInput]
    public let actions: [ActionInput]
    public let minimumStrengthRank: Int?
    public let budgetCap: Decimal?
    public let workReference: String?

    public init(
        title: String, goal: String, details: String?, criteria: [CriterionInput], actions: [ActionInput] = [],
        minimumStrengthRank: Int? = nil, budgetCap: Decimal? = nil, workReference: String?
    ) {
        self.title = title
        self.goal = goal
        self.details = details
        self.criteria = criteria
        self.actions = actions
        self.minimumStrengthRank = minimumStrengthRank
        self.budgetCap = budgetCap
        self.workReference = workReference
    }

    enum CodingKeys: String, CodingKey {
        case title, goal, details, criteria, actions
        case minimumStrengthRank = "minimum_strength_rank"
        case budgetCap = "budget_cap"
        case workReference = "work_reference"
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(title, forKey: .title)
        try container.encode(goal, forKey: .goal)
        try container.encode(details, forKey: .details)
        try container.encode(criteria, forKey: .criteria)
        try container.encode(actions, forKey: .actions)
        try container.encode(minimumStrengthRank, forKey: .minimumStrengthRank)
        try container.encode(budgetCap, forKey: .budgetCap)
        try container.encode(workReference, forKey: .workReference)
    }
}

/// `ConnectSeatRequest` (IN-29): model and effort are sent as null when
/// empty, which is the tool's default.
public struct ConnectSeatRequest: Encodable, Equatable, Sendable {
    public let name: String
    public let role: SeatRole
    public let provider: Provider?
    public let model: String?
    public let effort: String?
    public let strengthRank: Int?
    /// The login a seat the app runs uses; nil for a seat that connects on
    /// its own.
    public let credentialID: UUID?

    public init(
        name: String, role: SeatRole, provider: Provider? = nil, model: String? = nil, effort: String? = nil,
        strengthRank: Int? = nil, credentialID: UUID? = nil
    ) {
        self.name = name
        self.role = role
        self.provider = provider
        self.model = model.flatMap { $0.isEmpty ? nil : $0 }
        self.effort = effort.flatMap { $0.isEmpty ? nil : $0 }
        self.strengthRank = strengthRank
        self.credentialID = credentialID
    }

    enum CodingKeys: String, CodingKey {
        case name, role, provider, model, effort
        case strengthRank = "strength_rank"
        case credentialID = "credential_id"
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(role, forKey: .role)
        try container.encode(provider, forKey: .provider)
        try container.encode(model, forKey: .model)
        try container.encode(effort, forKey: .effort)
        try container.encode(strengthRank, forKey: .strengthRank)
        try container.encodeID(credentialID, forKey: .credentialID)
    }
}

/// `IssueHelperTokenRequest`.
public struct IssueHelperTokenRequest: Encodable, Equatable, Sendable {
    public let name: String

    public init(name: String) {
        self.name = name
    }
}

/// `AddCredentialRequest` (IN-24): the app sends null masked label, model,
/// effort and strength rank for a login.
public struct AddCredentialRequest: Encodable, Equatable, Sendable {
    public let credentialID: UUID
    public let kind: CredentialKind
    public let provider: Provider
    public let name: String
    public let maskedLabel: String?
    public let model: String?
    public let effort: String?
    public let strengthRank: Int?

    public init(
        credentialID: UUID, kind: CredentialKind = .login, provider: Provider, name: String,
        maskedLabel: String? = nil, model: String? = nil, effort: String? = nil, strengthRank: Int? = nil
    ) {
        self.credentialID = credentialID
        self.kind = kind
        self.provider = provider
        self.name = name
        self.maskedLabel = maskedLabel
        self.model = model
        self.effort = effort
        self.strengthRank = strengthRank
    }

    enum CodingKeys: String, CodingKey {
        case kind, provider, name, model, effort
        case credentialID = "credential_id"
        case maskedLabel = "masked_label"
        case strengthRank = "strength_rank"
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeID(credentialID, forKey: .credentialID)
        try container.encode(kind, forKey: .kind)
        try container.encode(provider, forKey: .provider)
        try container.encode(name, forKey: .name)
        try container.encode(maskedLabel, forKey: .maskedLabel)
        try container.encode(model, forKey: .model)
        try container.encode(effort, forKey: .effort)
        try container.encode(strengthRank, forKey: .strengthRank)
    }
}

/// `InstallToolRequest`: sent only after the owner confirmed.
public struct InstallToolRequest: Encodable, Equatable, Sendable {
    public let confirmed: Bool

    public init() {
        confirmed = true
    }
}

/// `AcknowledgeBriefingRequest`.
public struct AcknowledgeBriefingRequest: Encodable, Equatable, Sendable {
    public let briefingHash: String

    public init(briefingHash: String) {
        self.briefingHash = briefingHash
    }

    enum CodingKeys: String, CodingKey {
        case briefingHash = "briefing_hash"
    }
}

/// The evidence of `PassCriterionRequest`: an `https` link, or a note
/// locating the proof inside the work reference.
public struct EvidenceInput: Encodable, Equatable, Sendable {
    public let kind: EvidenceKind
    public let value: String

    public init(kind: EvidenceKind, value: String) {
        self.kind = kind
        self.value = value
    }
}

/// `PassCriterionRequest`.
public struct PassCriterionRequest: Encodable, Equatable, Sendable {
    public let evidence: EvidenceInput

    public init(evidence: EvidenceInput) {
        self.evidence = evidence
    }
}

/// `SubmitTaskRequest`.
public struct SubmitTaskRequest: Encodable, Equatable, Sendable {
    public let handoffNote: String
    public let workReference: String?

    public init(handoffNote: String, workReference: String?) {
        self.handoffNote = handoffNote
        self.workReference = workReference
    }

    enum CodingKeys: String, CodingKey {
        case handoffNote = "handoff_note"
        case workReference = "work_reference"
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(handoffNote, forKey: .handoffNote)
        try container.encode(workReference, forKey: .workReference)
    }
}

/// `ReleaseTaskRequest`: a reason a seat may choose.
public struct ReleaseTaskRequest: Encodable, Equatable, Sendable {
    public let reason: ReleaseReason

    public init(reason: ReleaseReason) {
        self.reason = reason
    }
}

/// `GiveVerdictRequest`. Tokens are what the tool's output gives (0 where
/// it gives none) and spend is 0 for a login (CL-11).
public struct GiveVerdictRequest: Encodable, Equatable, Sendable {
    public let verdict: ReviewVerdict
    public let failedCriteria: [UUID]
    public let notes: String
    public let tokens: Int
    public let spend: Decimal

    public init(verdict: ReviewVerdict, failedCriteria: [UUID], notes: String, tokens: Int, spend: Decimal = 0) {
        self.verdict = verdict
        self.failedCriteria = failedCriteria
        self.notes = notes
        self.tokens = tokens
        self.spend = spend
    }

    enum CodingKeys: String, CodingKey {
        case verdict, notes, tokens, spend
        case failedCriteria = "failed_criteria"
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(verdict, forKey: .verdict)
        try container.encodeIDs(failedCriteria, forKey: .failedCriteria)
        try container.encode(notes, forKey: .notes)
        try container.encode(tokens, forKey: .tokens)
        try container.encode(spend, forKey: .spend)
    }
}

/// `ReportRequestResultRequest`.
public struct ReportRequestResultRequest: Encodable, Equatable, Sendable {
    public let result: HelperRequestResult

    public init(result: HelperRequestResult) {
        self.result = result
    }
}

/// `RunStartedReport`.
public struct RunStartedReport: Encodable, Equatable, Sendable {
    public let credentialID: UUID
    public let observedAt: Date
    public let toolVersion: String

    public init(credentialID: UUID, observedAt: Date, toolVersion: String) {
        self.credentialID = credentialID
        self.observedAt = observedAt
        self.toolVersion = toolVersion
    }

    enum CodingKeys: String, CodingKey {
        case credentialID = "credential_id"
        case observedAt = "observed_at"
        case toolVersion = "tool_version"
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeID(credentialID, forKey: .credentialID)
        try container.encode(observedAt, forKey: .observedAt)
        try container.encode(toolVersion, forKey: .toolVersion)
    }
}

/// `RunStoppedReport`.
public struct RunStoppedReport: Encodable, Equatable, Sendable {
    public let credentialID: UUID
    public let observedAt: Date
    public let stopReason: RunStopReason

    public init(credentialID: UUID, observedAt: Date, stopReason: RunStopReason) {
        self.credentialID = credentialID
        self.observedAt = observedAt
        self.stopReason = stopReason
    }

    enum CodingKeys: String, CodingKey {
        case credentialID = "credential_id"
        case observedAt = "observed_at"
        case stopReason = "stop_reason"
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeID(credentialID, forKey: .credentialID)
        try container.encode(observedAt, forKey: .observedAt)
        try container.encode(stopReason, forKey: .stopReason)
    }
}

/// One field of `ChangeSeatRequest`: left as it is, set, or (where the
/// field allows it) cleared to null, which for `model` and `effort` is the
/// tool's default.
public enum Setting<Value: Equatable & Sendable>: Equatable, Sendable {
    case keep
    case set(Value)
    case clear
}

/// `ChangeSeatRequest` (HE-27, HM-51): only the fields the owner changed are
/// sent.
public struct ChangeSeatRequest: Encodable, Equatable, Sendable {
    public var name: String?
    public var role: SeatRole?
    public var model: Setting<String>
    public var effort: Setting<String>
    public var strengthRank: Setting<Int>
    public var credentialID: Setting<UUID>
    public var enabled: Bool?

    public init(
        name: String? = nil, role: SeatRole? = nil, model: Setting<String> = .keep,
        effort: Setting<String> = .keep, strengthRank: Setting<Int> = .keep,
        credentialID: Setting<UUID> = .keep, enabled: Bool? = nil
    ) {
        self.name = name
        self.role = role
        self.model = model
        self.effort = effort
        self.strengthRank = strengthRank
        self.credentialID = credentialID
        self.enabled = enabled
    }

    public func encode(to encoder: any Encoder) throws {}
}
