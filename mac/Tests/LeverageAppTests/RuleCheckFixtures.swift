import Foundation
import LeverageKit

/// Made-up values for the rule checks on the task page, the board and Add task
/// (milestone 4). They sit beside `TaskScreenFixtures` so that file stays as
/// milestone 3 left it.
extension TaskScreenFixtures {
    /// The moment the page's open step and lifetime are measured to.
    static let pageAsOf = date(19, 10)

    static func step(
        _ kind: StepKind, _ stepClass: StepClass = .working, seconds: Double, open: Bool = false, round: Int = 0,
        causeRule: UUID? = nil
    ) -> TaskStepRow {
        let opened = pageAsOf.addingTimeInterval(-seconds)
        return TaskStepRow(
            kind: kind, stepClass: stepClass, round: round, openedAt: opened, closedAt: open ? nil : pageAsOf,
            seconds: seconds, causeKind: causeRule == nil ? nil : .rule, causeRuleID: causeRule)
    }

    static func check(
        id: UUID = UUID(), rule: String = "Every task needs specific details", ruleID: UUID = UUID(),
        hook: RuleHook = .taskBeforeReady, checker: RuleChecker = .model, onFail: RuleOnFail? = .block,
        result: CheckResult? = .passed, effect: RuleEffect? = nil, reason: String? = nil,
        queue: Double? = nil, run: Double? = nil, saved: Date = date(12, 9), overriddenAt: Date? = nil,
        overrideReason: String? = nil, canOverride: Bool = false, canRerun: Bool = false
    ) -> RuleCheckRow {
        RuleCheckRow(
            id: id, ruleID: ruleID, ruleName: rule, ruleVersionID: UUID(), version: 1, versionSavedAt: saved,
            hook: hook, momentName: hook.momentName, checker: checker, onFail: onFail, result: result,
            effect: effect, reason: reason, queueSeconds: queue, runSeconds: run, overriddenAt: overriddenAt,
            overrideReason: overrideReason, canOverride: canOverride, canRerun: canRerun)
    }

    /// A task read with the milestone 4 fields.
    static func checkedPage(
        _ task: TaskSummary, criteria: [Criterion] = [], holds: [Hold] = [], steps: [TaskStepRow] = [],
        lifetime: Double? = nil, checks: [RuleCheckRow] = [], pending: PendingState? = nil,
        draft: DraftState = .none, events: [EventRecord] = [], names: [LogName] = [], asOfSeq: Int = 20
    ) -> TaskPage {
        TaskPage(
            task: task, criteria: criteria, holds: holds, events: events, names: names, reviewerSeatExists: true,
            asOfSeq: asOfSeq, steps: steps, lifetimeSeconds: lifetime ?? steps.reduce(0) { $0 + $1.seconds },
            asOf: pageAsOf, ruleChecks: checks, pending: pending, draft: draft)
    }

    /// A rule as the Rules list answers it.
    static func ruleRow(key: String, name: String, enabled: Bool = true) -> RuleRow {
        let ruleID = UUID()
        let version = RuleVersion(
            id: UUID(), ruleID: ruleID, version: 1, key: key, name: name, hook: .taskBeforeReady,
            scope: .allTasks, kind: .gate, checker: .app, onFail: .block, origin: .shipped, authorKind: .app,
            createdAt: date(1, 9))
        return RuleRow(
            rule: RuleRecord(id: ruleID, key: key, enabled: enabled, currentVersion: 1), version: version,
            momentName: "when a task is ready to start",
            stats: RuleStats(checks: 0, averageSeconds: nil, tokens: 0, spend: 0, overrides: 0))
    }
}
