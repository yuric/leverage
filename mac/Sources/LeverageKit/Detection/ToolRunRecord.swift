import Foundation

/// What a detector is given: how one tool run ended and both its outputs
/// (plan §2.2, HD-5). It is held in memory only and never logged, written or
/// sent (CL-29): it is not `Codable`, and printing, dumping or interpolating
/// it shows the exit status and the outputs' sizes, never their text.
public struct ToolRunRecord: Equatable, Sendable {
    public let termination: SubprocessTermination
    public let standardOutput: Data
    public let standardError: Data
    /// Why leverage ended the run, when it did.
    public let endedBy: SubprocessEnd?

    public init(
        termination: SubprocessTermination, standardOutput: Data, standardError: Data,
        endedBy: SubprocessEnd? = nil
    ) {
        self.termination = termination
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.endedBy = endedBy
    }

    public init(_ result: SubprocessResult) {
        self.init(
            termination: result.termination, standardOutput: result.standardOutput,
            standardError: result.standardError, endedBy: result.endedBy)
    }

    /// Standard output as text, for a detector's rules.
    public var outputText: String { String(decoding: standardOutput, as: UTF8.self) }
    /// Standard error as text, for a detector's rules.
    public var errorText: String { String(decoding: standardError, as: UTF8.self) }
}

extension ToolRunRecord: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        "ToolRunRecord(\(termination), output: \(standardOutput.count) bytes, "
            + "error: \(standardError.count) bytes, endedBy: \(endedBy.map { "\($0)" } ?? "nil"))"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(self, children: [
            "termination": termination,
            "outputBytes": standardOutput.count,
            "errorBytes": standardError.count,
            "endedBy": endedBy as Any,
        ])
    }
}
