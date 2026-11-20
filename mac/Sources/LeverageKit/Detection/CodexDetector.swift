import Foundation

/// The detector for Codex's replies (plan HD-7, HD-8).
///
/// A placeholder: it knows no rule yet and answers `failed` for every run,
/// so a runner built with it behaves as milestone 2's. WP2c writes its rules.
public struct CodexDetector: Detector {
    public init() {}

    public var provider: Provider { .codex }
    public var testedToolVersions: [String] { [] }
    public var rules: [DetectorRule] { [] }

    public func outcome(of run: ToolRunRecord, at now: Date) -> RunOutcome { .failed }
}
