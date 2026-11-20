import Foundation

public struct GrokDetector: Detector {
    public init() {}

    public var provider: Provider { .grok }
    public var testedToolVersions: [String] { [] }
    public var rules: [DetectorRule] { [] }

    public func outcome(of run: ToolRunRecord, at now: Date) -> RunOutcome { .failed }
}
