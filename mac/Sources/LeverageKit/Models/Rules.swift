import Foundation

// The rules and what the owner sends to change them (milestone 4 plan
// sections 2.2 and 2.3). The Swift names are the plan's: `RuleRecord` is
// the contract's `Rule`, `RuleRow` its `RuleWithVersion`.

/// `Rule`: the rule itself; its fields live in its versions.
public struct RuleRecord: Codable, Equatable, Sendable {
    public let id: UUID
    public let key: String
    public let enabled: Bool
    public let currentVersion: Int

    public init(id: UUID, key: String, enabled: Bool, currentVersion: Int) {
        self.id = id
        self.key = key
        self.enabled = enabled
        self.currentVersion = currentVersion
    }

}

/// `RuleScope`: which tasks a rule applies to. `named_projects` uses
/// `project_ids`, `action_kinds` uses `action_kinds`, the other kinds
/// neither. It is read from a version and sent with Add rule and Save rule,
/// where every key is written, null where it does not apply.
public struct RuleScope: Codable, Equatable, Sendable {
    public let kind: RuleScopeKind
    public let projectIDs: [UUID]?
    public let actionKinds: [ActionKind]?

    public init(kind: RuleScopeKind, projectIDs: [UUID]? = nil, actionKinds: [ActionKind]? = nil) {
        self.kind = kind
        self.projectIDs = projectIDs
        self.actionKinds = actionKinds
    }

    /// "Every task".
    public static let allTasks = RuleScope(kind: .allTasks)
    /// "The checker decides".
    public static let checkerDecides = RuleScope(kind: .checkerDecides)

}

/// `RuleVersion`: an immutable version of a rule. `enabled` lives on the rule.
public struct RuleVersion: Codable, Equatable, Sendable {
    public let id: UUID
    public let ruleID: UUID
    public let version: Int
    public let key: String
    public let name: String
    public let hook: RuleHook
    public let scope: RuleScope
    public let kind: RuleKind
    public let checker: RuleChecker
    public let onFail: RuleOnFail?
    public let route: RuleRoute?
    public let queueTimeoutSeconds: Int?
    public let runTimeoutSeconds: Int?
    /// A model-checked rule's instruction; nil for an app-checked rule.
    public let instruction: String?
    public let parameters: [String: JSONValue]?
    public let origin: RuleOrigin
    public let authorKind: ActorKind
    public let authorID: UUID?
    public let createdAt: Date

    public init(
        id: UUID, ruleID: UUID, version: Int, key: String, name: String, hook: RuleHook, scope: RuleScope,
        kind: RuleKind, checker: RuleChecker, onFail: RuleOnFail?, route: RuleRoute? = nil,
        queueTimeoutSeconds: Int? = nil, runTimeoutSeconds: Int? = nil, instruction: String? = nil,
        parameters: [String: JSONValue]? = nil, origin: RuleOrigin, authorKind: ActorKind, authorID: UUID? = nil,
        createdAt: Date
    ) {
        self.id = id
        self.ruleID = ruleID
        self.version = version
        self.key = key
        self.name = name
        self.hook = hook
        self.scope = scope
        self.kind = kind
        self.checker = checker
        self.onFail = onFail
        self.route = route
        self.queueTimeoutSeconds = queueTimeoutSeconds
        self.runTimeoutSeconds = runTimeoutSeconds
        self.instruction = instruction
        self.parameters = parameters
        self.origin = origin
        self.authorKind = authorKind
        self.authorID = authorID
        self.createdAt = createdAt
    }

}

/// `RuleStats`: how a rule has run (RD-26).
public struct RuleStats: Codable, Equatable, Sendable {
    /// Its check rows whose result is not `not_applicable` and not `withdrawn`.
    public let checks: Int
    /// Queue plus run time per finished attempt; nil when none finished.
    public let averageSeconds: Double?
    public let tokens: Int
    /// US dollars, as reported.
    public let spend: Decimal
    public let overrides: Int

    public init(checks: Int, averageSeconds: Double?, tokens: Int, spend: Decimal, overrides: Int) {
        self.checks = checks
        self.averageSeconds = averageSeconds
        self.tokens = tokens
        self.spend = spend
        self.overrides = overrides
    }

}

/// `RuleWithVersion`: one row of the Rules screen.
public struct RuleRow: Codable, Equatable, Sendable {
    public let rule: RuleRecord
    public let version: RuleVersion
    /// For an app-checked rule, the one sentence made from its function and
    /// parameters; nil for a model-checked rule (RD-62).
    public let sentence: String?
    /// When it runs: its hook's moment name, in the owner's words.
    public let momentName: String
    /// False for a rule whose effect arrives in a later milestone (RD-8).
    public let acts: Bool
    public let stats: RuleStats

    public init(
        rule: RuleRecord, version: RuleVersion, sentence: String? = nil, momentName: String, acts: Bool = true,
        stats: RuleStats
    ) {
        self.rule = rule
        self.version = version
        self.sentence = sentence
        self.momentName = momentName
        self.acts = acts
        self.stats = stats
    }

}

/// `RulesList`: `GET /v1/owner/rules`.
public struct RulesList: Codable, Equatable, Sendable {
    public let rules: [RuleRow]

    public init(rules: [RuleRow]) {
        self.rules = rules
    }
}

/// `AddRuleRequest`: a custom rule is a model-checked gate that blocks.
public struct AddRuleRequest: Encodable, Equatable, Sendable {
    public let name: String
    public let instruction: String
    public let hook: RuleHook
    public let scope: RuleScope

    public init(name: String, instruction: String, hook: RuleHook, scope: RuleScope) {
        self.name = name
        self.instruction = instruction
        self.hook = hook
        self.scope = scope
    }
}

/// `SaveRuleRequest`: every field, the unedited ones as they were (WP16's
/// editor sends the route too, whatever its value). Required keys are
/// always written, null where nil.
public struct SaveRuleRequest: Encodable, Equatable, Sendable {
    public let name: String
    public let instruction: String?
    public let parameters: [String: JSONValue]?
    public let scope: RuleScope
    public let onFail: RuleOnFail?
    public let route: RuleRoute?
    public let queueTimeoutSeconds: Int?
    public let runTimeoutSeconds: Int?

    public init(
        name: String, instruction: String?, parameters: [String: JSONValue]? = nil, scope: RuleScope,
        onFail: RuleOnFail?, route: RuleRoute?, queueTimeoutSeconds: Int? = nil, runTimeoutSeconds: Int? = nil
    ) {
        self.name = name
        self.instruction = instruction
        self.parameters = parameters
        self.scope = scope
        self.onFail = onFail
        self.route = route
        self.queueTimeoutSeconds = queueTimeoutSeconds
        self.runTimeoutSeconds = runTimeoutSeconds
    }

}

/// `OverrideCheckRequest`: why the owner lets one check through once. It is
/// stored with who and when, and counted per rule.
public struct OverrideCheckRequest: Encodable, Equatable, Sendable {
    public let reason: String

    public init(reason: String) {
        self.reason = reason
    }
}
