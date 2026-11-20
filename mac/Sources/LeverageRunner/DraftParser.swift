import Foundation
import LeverageKit

/// Reads a planner's contract from what its tool printed (milestone 4 plan
/// section 2.2). A placeholder for WP14: it answers "no draft" to
/// everything.
enum DraftParser {
    /// The independent review the Add task form adds (`AddTaskCopy`), used
    /// when the task has no review criterion of its own.
    static let reviewCriterion = "An independent reviewer agrees."

    /// The contract in `text`, or nil for no draft: the JSON object between
    /// the nonce's two markers, with the task's title kept, each sentence a
    /// `build` criterion, the one `review` criterion the Add task form adds,
    /// no actions, and `work_reference`, `minimum_strength_rank` and
    /// `budget_cap` sent back exactly as `material` gave them (RD-37).
    static func parse(_ text: String, nonce: String, material: DraftMaterial) -> CompleteContractRequest? { nil }
}
