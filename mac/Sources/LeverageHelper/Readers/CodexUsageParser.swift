import Foundation

enum CodexUsageParser {
    static func parse(rateLimits: Data, usage: Data) -> UsageReading {
        UsageReading(state: .unavailable)
    }
}
