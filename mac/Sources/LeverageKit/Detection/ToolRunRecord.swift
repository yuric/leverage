import Foundation

public struct ToolRunRecord: Equatable, Sendable {
    public let termination: SubprocessTermination
    public let standardOutput: Data
    public let standardError: Data
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

    public var outputText: String { "" }
    public var errorText: String { "" }
}
