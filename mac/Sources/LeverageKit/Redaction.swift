import Foundation

/// What is removed from a line before the Mac side writes it (plan CL-29):
/// leverage's tokens, recognised by their prefix (`lvs_` seat, `lvh_`
/// helper, `lvo_` owner session, IN-18), key-shaped provider tokens (TK-5),
/// the value of a bearer header, email addresses, and any value the caller
/// names. A tool's raw output is never logged at all.
public enum Redaction {
    /// Each pattern and what replaces a match of it. They are compiled
    /// where they are used: NSRegularExpression is not Sendable everywhere
    /// this builds (Linux), and logging is not on a hot path.
    private static let rules: [(pattern: String, template: String)] = [
        (#"\b(lv[sho]_)[A-Za-z0-9_\-]{8,}"#, "$1[removed]"),
        (#"(?i)\b(bearer)\s+[^\s"',;]+"#, "$1 [removed]"),
        (#"\b(?:sk-|xai-|AIza)[A-Za-z0-9_-]{16,}"#, "[removed]"),
        (#"[A-Za-z0-9._%+\-]+@[A-Za-z0-9\-]+(\.[A-Za-z0-9\-]+)+"#, "[email removed]"),
    ]

    /// `text` with every token, bearer value, email address and named value
    /// removed.
    public static func redact(_ text: String, removing secrets: [String] = []) -> String {
        var result = text
        for secret in secrets where !secret.isEmpty {
            result = result.replacingOccurrences(of: secret, with: "[removed]")
        }
        for (pattern, template) in rules {
            // The patterns are constants; a mistake in one fails every test.
            let expression = try! NSRegularExpression(pattern: pattern)
            let range = NSRange(result.startIndex..., in: result)
            result = expression.stringByReplacingMatches(
                in: result, range: range, withTemplate: template)
        }
        return result
    }
}
