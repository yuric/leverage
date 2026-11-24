import Foundation

enum ClaudeUsageParser {
    /// Step 0 established a JSON result envelope. Its text was scrubbed,
    /// and the retained numeric fields do not identify rate-limit windows.
    /// A quota grammar needs another sanitized observation before use.
    static func parse(_ stdout: Data) -> UsageReading {
        UsageReading(state: .unavailable)
    }
}
