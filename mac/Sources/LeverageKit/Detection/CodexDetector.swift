import Foundation

public struct CodexDetector: Detector {
    public init() {}

    public var provider: Provider { .codex }
    public var testedToolVersions: [String] { [] }
    public var rules: [DetectorRule] { [] }

    public func outcome(of run: ToolRunRecord, at now: Date) -> RunOutcome { .failed }
}
