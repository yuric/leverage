import Foundation
import LeverageKit
import Testing

@testable import LeverageApp

/// Made-up rules for the Settings tests. The seven shipped rules are read from
/// `api/contract/shipped_rules.json`, so the screen is tried on the real
/// names, moments, checkers and scopes and not on a copy of them.
enum RulesFixtures {
    static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    static let usEnglish = Locale(identifier: "en_US")
    /// 11 November 2026, 10:00 UTC.
    static let saved = Date(timeIntervalSince1970: 1_794_391_200)

    private static let repository: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    /// The sentences the server makes for an app rule (RD-62); made up here.
    static let sentences: [String: String] = [
        "acceptance_criteria": "Every task needs at least 1 acceptance criterion besides the review.",
        "ask_orchestrator_first": "Questions go to the agent that checks tasks first.",
        "different_provider_review": "An agent on a provider that built the task may not review it.",
        "escalate_after_failed_reviews": "After 2 failed reviews a task moves to a stronger model.",
        "project_budget_pause": "A project pauses when it reaches its budget.",
    ]

    /// The rules whose effect is a later milestone's (RD-8).
    static let notActing: Set<String> = [
        "ask_orchestrator_first", "escalate_after_failed_reviews", "project_budget_pause",
        "orchestrator_approves_actions",
    ]

    static func id(_ number: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", number))!
    }

    /// The seven shipped rules, in the file's order, as the server would answer them.
    static func shippedRows() throws -> [RuleRow] {
        let data = try Data(contentsOf: repository.appending(path: "api/contract/shipped_rules.json"))
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let rules = try #require(root["rules"] as? [[String: Any]])
        return try rules.enumerated().map { index, rule in
            let key = try #require(rule["key"] as? String)
            let scope = try #require(rule["scope"] as? [String: Any])
            let hook = try #require((rule["hook"] as? String).flatMap(RuleHook.init))
            let kind = try #require((rule["kind"] as? String).flatMap(RuleKind.init))
            let checker = try #require((rule["checker"] as? String).flatMap(RuleChecker.init))
            let scopeKind = try #require((scope["kind"] as? String).flatMap(RuleScopeKind.init))
            var parameters: [String: JSONValue] = [:]
            for (name, schema) in (rule["parameters"] as? [String: [String: Any]]) ?? [:] {
                if let value = schema["default"] as? Double { parameters[name] = .number(value) }
            }
            return row(
                number: index + 1, key: key, name: try #require(rule["name"] as? String), hook: hook, kind: kind,
                checker: checker, scope: RuleScope(kind: scopeKind),
                onFail: (rule["on_fail"] as? String).flatMap(RuleOnFail.init),
                route: (rule["route"] as? String).flatMap(RuleRoute.init), instruction: rule["instruction"] as? String,
                parameters: parameters.isEmpty ? nil : parameters, origin: .shipped,
                enabled: rule["enabled"] as? Bool ?? true, sentence: sentences[key], acts: !notActing.contains(key))
        }
    }

    static func stats(
        checks: Int = 0, average: Double? = nil, tokens: Int = 0, spend: Decimal = 0, overrides: Int = 0
    ) -> RuleStats {
        RuleStats(checks: checks, averageSeconds: average, tokens: tokens, spend: spend, overrides: overrides)
    }

    static func row(
        number: Int = 100, key: String? = nil, name: String = "Made-up rule", hook: RuleHook = .taskBeforeReady,
        kind: RuleKind = .gate, checker: RuleChecker = .model, scope: RuleScope = .allTasks,
        onFail: RuleOnFail? = .block, route: RuleRoute? = .owner, queueTimeout: Int? = nil, runTimeout: Int? = nil,
        instruction: String? = "A made-up instruction.", parameters: [String: JSONValue]? = nil,
        origin: RuleOrigin = .custom, enabled: Bool = true, sentence: String? = nil, acts: Bool = true,
        stats: RuleStats = RulesFixtures.stats(), version: Int = 1
    ) -> RuleRow {
        let key = key ?? "custom_\(number)"
        return RuleRow(
            rule: RuleRecord(id: id(number), key: key, enabled: enabled, currentVersion: version),
            version: RuleVersion(
                id: id(number + 1000), ruleID: id(number), version: version, key: key, name: name, hook: hook,
                scope: scope, kind: kind, checker: checker, onFail: onFail, route: route,
                queueTimeoutSeconds: queueTimeout, runTimeoutSeconds: runTimeout,
                instruction: checker == .model ? instruction : nil, parameters: parameters, origin: origin,
                authorKind: origin == .shipped ? .app : .owner, createdAt: saved),
            sentence: checker == .app ? sentence : nil, momentName: hook.momentName, acts: acts, stats: stats)
    }
}
