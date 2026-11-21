import Foundation

struct ClaudeUsageReader: UsageReader {
    func read(_ account: ReaderAccount) async throws -> UsageReading {
        UsageReading(state: .unavailable)
    }
}
