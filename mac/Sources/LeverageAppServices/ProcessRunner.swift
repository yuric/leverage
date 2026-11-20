import Foundation
import LeverageKit

/// Runs one child process to its end. The server supervisor and the Docker
/// locator take it as a parameter; the app passes `SystemProcessRunner`,
/// and a test may wrap it to see what was run.
public protocol ProcessRunning: Sendable {
    func run(_ request: SubprocessRequest) async throws -> SubprocessResult
}

/// `ProcessRunning` through LeverageKit's `Subprocess`, the Mac side's one
/// way to run a child process.
public struct SystemProcessRunner: ProcessRunning {
    public init() {}

    public func run(_ request: SubprocessRequest) async throws -> SubprocessResult {
        try await Subprocess.run(request)
    }
}

extension SubprocessResult {
    /// The last line of standard error, else of standard output, cut to 300
    /// characters and redacted: a reason for the log.
    var lastLine: String {
        for data in [standardError, standardOutput] {
            let text = String(decoding: data, as: UTF8.self)
            if let line = text.split(whereSeparator: \.isNewline).last(where: { !$0.allSatisfy(\.isWhitespace) }) {
                return Redaction.redact(String(line.prefix(300)))
            }
        }
        return ""
    }

    var exitDescription: String {
        switch termination {
        case .exited(let code): return "exit \(code)"
        case .signaled(let signal): return "signal \(signal)"
        }
    }
}
