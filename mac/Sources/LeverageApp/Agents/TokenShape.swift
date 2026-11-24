import Foundation

/// Whether a text holds something shaped like one of Leverage's tokens
/// (`lvs_`, `lvh_`, `lvo_` and then a long run of letters, digits, `_` or
/// `-`; IN-18). A landing prompt never holds one, so the app refuses to show
/// or copy a text that does.
enum TokenShape {
    static func isIn(_ text: String) -> Bool {
        text.range(of: #"\blv[sho]_[A-Za-z0-9_\-]{8,}"#, options: .regularExpression) != nil
    }
}
