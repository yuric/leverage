import Foundation
import LeverageKit

/// One line of the Timing section: a step, its plain name and how long it took.
struct TimingRow: Identifiable, Equatable, Sendable {
    let id: Int
    let kind: StepKind
    let name: String
    let seconds: Double
    let durationText: String
    /// The step is still open: its time is counted to the page's reading.
    let isOpen: Bool
}

/// The Timing section: the steps in order, the time before the task left
/// Ideas listed apart, and the total, which is the task's lifetime (RD-28).
struct TimingContent: Equatable, Sendable {
    let rows: [TimingRow]
    let beforeIdeas: TimingRow?
    let totalSeconds: Double
    let totalText: String
}

/// One line of the checklist: a check, in the owner's words (RD-28).
struct CheckRowContent: Identifiable, Equatable, Sendable {
    let id: UUID
    let ruleName: String
    let momentText: String
    let resultText: String
    /// Text a model wrote about the task: shown as it was written.
    let reason: String?
    let timeText: String?
    let wordingText: String
    let checkerText: String
    let onFailText: String?
    /// "You let it through", with the owner's reason, once it was let through.
    let overrideText: String?
    let isGreyed: Bool
    let canLetThrough: Bool
    let canRunAgain: Bool
}

extension TaskPageModel {
    /// The Timing section, or nil when the read carries no steps. The time before
    /// the task left Ideas is listed apart, outside the total: the total runs
    /// from the move to Backlog, as the reports measure a task (PRD rule 7,
    /// L282, L321), so the rows alone add up to it (review finding 23).
    var timing: TimingContent? {
        guard let page, !page.steps.isEmpty else { return nil }
        var rows: [TimingRow] = []
        var ideaSeconds = 0.0
        var ideaIndex: Int?
        for (index, step) in page.steps.enumerated() {
            if step.kind == .idea {
                ideaSeconds += step.seconds
                ideaIndex = ideaIndex ?? index
                continue
            }
            rows.append(Self.timingRow(index, step.kind, step.seconds, open: step.closedAt == nil))
        }
        let beforeIdeas = ideaIndex.map { Self.timingRow($0, .idea, ideaSeconds, open: false) }
        let total = max(page.lifetimeSeconds - ideaSeconds, 0)
        return TimingContent(
            rows: rows, beforeIdeas: beforeIdeas, totalSeconds: total, totalText: Self.duration(total))
    }

    private static func timingRow(_ index: Int, _ kind: StepKind, _ seconds: Double, open: Bool) -> TimingRow {
        TimingRow(
            id: index, kind: kind, name: TaskPageCopy.stepName(kind).text, seconds: seconds,
            durationText: duration(seconds), isOpen: open)
    }

    private static func duration(_ seconds: Double) -> String {
        DurationWords.text(seconds: Int(seconds.rounded()))
    }

    /// The checklist, one line for each check in order of creation, those that
    /// did not apply and the policies greyed (RD-28, RD-49).
    var checks: [CheckRowContent] {
        guard let page else { return [] }
        return page.ruleChecks.map { row in
            let overridden = row.overriddenAt != nil
            let time: String? = (row.queueSeconds == nil && row.runSeconds == nil)
                ? nil : Self.duration((row.queueSeconds ?? 0) + (row.runSeconds ?? 0))
            let onFail: String? = switch row.onFail {
            case .block: TaskPageCopy.onFailBlock.text
            case .warn: TaskPageCopy.onFailWarn.text
            case nil: nil
            }
            var overrideText: String?
            if overridden {
                let why = row.overrideReason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                overrideText = why.isEmpty
                    ? TaskPageCopy.youLetItThrough.text : TaskPageCopy.youLetItThroughWhy.filled(["reason": why])
            }
            return CheckRowContent(
                id: row.id, ruleName: row.ruleName, momentText: row.momentName, resultText: Self.resultText(row),
                reason: row.reason, timeText: time,
                wordingText: TaskPageCopy.wordingOf.filled(["date": Self.dateText(row.versionSavedAt, clock: clock)]),
                checkerText: (row.checker == .app ? TaskPageCopy.checkerApp : .checkerModel).text,
                onFailText: onFail, overrideText: overrideText,
                isGreyed: row.result == .notApplicable || row.result == .withdrawn || row.onFail == nil,
                canLetThrough: row.canOverride && !overridden, canRunAgain: row.canRerun && !overridden)
        }
    }

    private static func resultText(_ row: RuleCheckRow) -> String {
        switch row.result {
        case .passed: TaskPageCopy.checkPassed.text
        case .failed: TaskPageCopy.checkFailed.text
        case .notApplicable: TaskPageCopy.checkNotApplicable.text
        case .applied: TaskPageCopy.checkApplied.text
        case .error: TaskPageCopy.checkError.text
        case .withdrawn: TaskPageCopy.checkWithdrawn.text
        // A check with no result is running, or is the one held at the re-run limit, which waits for the owner.
        case nil: (row.canOverride ? TaskPageCopy.checkTooManyTimes : TaskPageCopy.checkBeingChecked).text
        }
    }

    /// The day a rule's wording was saved: the Mac's short date, in the card's calendar.
    private static func dateText(_ date: Date, clock: ResetClock) -> String {
        let calendar = clock.calendar
        return date.formatted(
            Date.FormatStyle(
                date: .abbreviated, time: .omitted, locale: clock.locale, calendar: calendar,
                timeZone: calendar.timeZone))
    }

    /// What the page says while a command waits for its checks, naming the
    /// rules it waits on when the page lists them (RD-29).
    var pendingLine: String? {
        guard let page, let pending = page.pending else { return nil }
        var names: [String] = []
        for id in pending.waitingOnRuleIDs {
            guard let name = page.ruleChecks.first(where: { $0.ruleID == id })?.ruleName, !names.contains(name) else {
                continue
            }
            names.append(name)
        }
        if names.isEmpty { return TaskPageCopy.beingChecked.text }
        return TaskPageCopy.beingCheckedBy.filled(["rules": names.joined(separator: ", ")])
    }

    /// The reason of the last failed check that keeps a task's contract
    /// incomplete, while that hold is open and the owner has not let it through.
    var contractCheckReason: String? {
        guard let page, openHolds.contains(where: { $0.reason == .contractIncomplete }) else { return nil }
        let reason = page.ruleChecks.last {
            $0.hook == .taskBeforeReady && $0.result == .failed && $0.overriddenAt == nil
                && !($0.reason ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }?.reason
        return reason
    }

    var draftState: DraftState { page?.draft ?? .none }

    /// What the page says of a contract draft that is under way or was not written.
    var draftLine: String? {
        switch draftState {
        case .none: nil
        case .queued: TaskPageCopy.draftQueued.text
        case .writing: TaskPageCopy.draftWriting.text
        case .notWritten: TaskPageCopy.draftNotWritten.text
        }
    }

    /// Draft the details: a Backlog task with no draft under way and no check running.
    var canDraftDetails: Bool {
        guard let page, page.task.state == .backlog, page.pending == nil, !isBusy else { return false }
        return draftState == .none || draftState == .notWritten
    }
}
