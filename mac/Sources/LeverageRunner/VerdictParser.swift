import Foundation
import LeverageKit

/// Reads a checker's verdict from what its tool printed (milestone 4 plan
/// section 2.2, RD-31). Only lines that carry the run's nonce are read, and
/// none inside a block the tool echoed back; nothing the tool printed is
/// ever logged.
enum VerdictParser {
    static let noReason = "No reason given."

    /// The verdict in `text`, or nil for no verdict. Exactly one verdict line
    /// and at most one reason line count; anything else is no verdict. The
    /// reason is trimmed, cut to `RuleCheckVerdict.reasonLimit` characters,
    /// and "No reason given." when missing. `not_applicable` counts only when
    /// `mayAnswerNotApplicable` says the job allows it.
    static func parse(_ text: String, nonce: String, mayAnswerNotApplicable: Bool) -> RuleCheckVerdict? {
        let verdictMarker = JobPrompts.verdictMarker(nonce) + ":"
        let reasonMarker = JobPrompts.reasonMarker(nonce) + ":"
        var verdicts: [String] = []
        var reasons: [String] = []
        for line in AnswerLines.outsideEchoedBlocks(text, nonce: nonce) {
            if let value = AnswerLines.value(of: line, after: verdictMarker) {
                // The answer's form, echoed back ("<PASSED or FAILED>"), is
                // no verdict line.
                if !value.hasPrefix("<") { verdicts.append(value) }
            } else if let value = AnswerLines.value(of: line, after: reasonMarker) {
                if !value.hasPrefix("<") { reasons.append(value) }
            }
        }
        guard verdicts.count == 1, reasons.count <= 1, let result = verdict(verdicts[0]) else { return nil }
        if result == .notApplicable, !mayAnswerNotApplicable { return nil }
        return RuleCheckVerdict(result: result, reason: reason(reasons.first))
    }

    private static func verdict(_ word: String) -> CheckVerdict? {
        switch word.uppercased() {
        case "PASSED": .passed
        case "FAILED": .failed
        case "NOT_APPLICABLE": .notApplicable
        default: nil
        }
    }

    /// Trimmed, at most 500 characters as the server counts them (Unicode
    /// scalars, as JSON Schema's `maxLength` does), or "No reason given.".
    private static func reason(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return noReason }
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: value.unicodeScalars.prefix(RuleCheckVerdict.reasonLimit))
        let cut = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        return cut.isEmpty ? noReason : cut
    }
}

/// The lines of a job tool's answer that may be read (milestone 4 plan
/// section 2.2), shared by `VerdictParser` and `DraftParser`.
enum AnswerLines {
    /// Each line, with every block the tool echoed back left out: from a
    /// line that opens a block with this run's nonce to the line that closes
    /// it. A block that is never closed hides the rest of the answer. Each
    /// line is trimmed of spaces and wrapping when `trim` says so.
    static func outsideEchoedBlocks(_ text: String, nonce: String, trim: Bool = true) -> [String] {
        let opening = JobPrompts.quoteOpening(nonce)
        let closing = JobPrompts.quoteClosing(nonce)
        var kept: [String] = []
        var inBlock = false
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = String(raw)
            if inBlock {
                if line.contains(closing) { inBlock = false }
                continue
            }
            if let open = line.range(of: opening) {
                inBlock = !line[open.upperBound...].contains(closing)
                continue
            }
            kept.append(trim ? line.trimmingCharacters(in: wrapping) : line)
        }
        return kept
    }

    /// Spaces and the marks a model may wrap a line in: emphasis, code.
    static let wrapping = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "*`"))

    /// What follows `marker` at the start of `line`, trimmed of spaces and
    /// wrapping; nil when the line does not start with it.
    static func value(of line: String, after marker: String) -> String? {
        guard line.hasPrefix(marker) else { return nil }
        return line.dropFirst(marker.count).trimmingCharacters(in: wrapping)
    }
}
