import Foundation

enum ClaudeUsageParser {
    static func parse(_ stdout: Data) -> UsageReading {
        UsageReading(state: .unavailable)
    }
}
