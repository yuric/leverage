import Foundation
import LeverageKit

/// Reads a checker's verdict from what its tool printed (milestone 4 plan
/// section 2.2). A placeholder for WP14: it answers "no verdict" to
/// everything.
enum VerdictParser {
    /// The verdict in `text`, or nil for no verdict. Only lines that carry
    /// the run's nonce are read; exactly one verdict line and at most one
    /// reason line count, anything else is no verdict. The reason is
    /// trimmed, cut to `RuleCheckVerdict.reasonLimit` characters, and "No
    /// reason given." when missing. `not_applicable` counts only when
    /// `mayAnswerNotApplicable` says the job allows it.
    static func parse(_ text: String, nonce: String, mayAnswerNotApplicable: Bool) -> RuleCheckVerdict? { nil }
}
