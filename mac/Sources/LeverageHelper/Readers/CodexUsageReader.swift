struct CodexUsageReader: UsageReader {
    func read(_ account: ReaderAccount) async throws -> UsageReading {
        UsageReading(state: .unavailable)
    }
}
