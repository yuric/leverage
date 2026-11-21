import Foundation
import LeverageKit

struct ClaudeUsageReader: UsageReader {
    func read(_ account: ReaderAccount) async throws -> UsageReading {
        try Task.checkCancellation()
        guard let folder = account.accountFolder, account.environment["CLAUDE_CONFIG_DIR"] == folder.path,
              account.entry.id == Provider.claude.rawValue, account.deadline > .now else {
            return UsageReading(state: .unavailable)
        }
        let result = try await Subprocess.run(SubprocessRequest(
            executable: account.tool.path,
            arguments: [
                "-p", "/usage", "--output-format", "json", "--no-session-persistence",
                "--permission-mode", "dontAsk", "--strict-mcp-config", "--setting-sources", "user", "--tools", "",
            ],
            environment: account.environment, workingDirectory: account.workingDirectory.path,
            timeLimit: account.deadline - .now, gracePeriod: .seconds(1), maximumOutputBytes: 1 << 20))
        guard result.succeeded, !result.outputTruncated else { return UsageReading(state: .unavailable) }
        return ClaudeUsageParser.parse(result.standardOutput)
    }
}
