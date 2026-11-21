import Foundation
import LeverageKit

struct UsageReading: Equatable, Sendable {
    let state: ReadingState
    var figures: [Figure] = []
    var resets: [Reset]?
}

struct ReaderAccount: Sendable {
    let entry: ProviderEntry
    let tool: LocatedTool
    let accountFolder: URL?
    let environment: [String: String]
    let workingDirectory: URL
    let deadline: ContinuousClock.Instant
}

protocol UsageReader: Sendable {
    func read(_ account: ReaderAccount) async throws -> UsageReading
}

enum UsageReaders {
    typealias Lookup = @Sendable (Provider) -> (any UsageReader)?

    static func reader(for provider: Provider) -> (any UsageReader)? {
        switch provider {
        case .codex: CodexUsageReader()
        // Claude's recorded envelope has no recoverable quota grammar.
        default: nil
        }
    }
}
