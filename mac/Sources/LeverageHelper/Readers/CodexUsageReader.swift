struct CodexUsageReader: UsageReader {
    func read(_ account: ReaderAccount) async throws -> UsageReading {
        guard let replies = await CodexAppServer.usage(account) else { return UsageReading(state: .unavailable) }
        return CodexUsageParser.parse(rateLimits: replies.rateLimits, usage: replies.usage)
    }
}
