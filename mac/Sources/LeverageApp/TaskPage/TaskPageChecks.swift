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
    /// The Timing section, or nil when the read carries no steps.
    var timing: TimingContent? { nil }

    /// The checklist, one line for each check in order of creation.
    var checks: [CheckRowContent] { [] }

    /// What the page says while a command waits for its checks.
    var pendingLine: String? { nil }

    var draftState: DraftState { .none }

    /// What the page says of a contract draft that is under way or was not written.
    var draftLine: String? { nil }

    /// Draft the details: a Backlog task with no draft under way and no check running.
    var canDraftDetails: Bool { false }
}
