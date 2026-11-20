import Foundation

public struct ClaudeDetector: Detector {
    public init() {}

    public var provider: Provider { .claude }
    public var testedToolVersions: [String] { [] }
    public var rules: [DetectorRule] { [] }

    public func outcome(of run: ToolRunRecord, at now: Date) -> RunOutcome { .failed }
}
