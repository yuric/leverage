import Foundation

public struct AntigravityDetector: Detector {
    public init() {}

    public var provider: Provider { .gemini }
    public var testedToolVersions: [String] { [] }
    public var rules: [DetectorRule] { [] }

    public func outcome(of run: ToolRunRecord, at now: Date) -> RunOutcome { .failed }
}
