import Foundation

/// How a reply file a detector rule follows was obtained (plan HD-8). The
/// reply files' `meta.basis` spells it the same way.
public enum ReplyBasis: String, CaseIterable, Sendable {
    /// Recorded on this Mac from a tool with no login (a folder that never
    /// held one, or this Mac as it is for Grok).
    case recordedNoLogin = "recorded_no_login"
    /// Made up: no reply of this kind has been seen.
    case invented
    /// Made to follow observed text, which the file names.
    case madeFromObserved = "made_from_observed"
}

/// One fixed rule of a detector, and the reply file that drives it.
public struct DetectorRule: Equatable, Sendable {
    /// What the rule recognises, in a few words.
    public let name: String
    /// The reply file under `mac/Tests/StandIns/replies/<provider>/`.
    public let replyFile: String
    public let basis: ReplyBasis

    public init(name: String, replyFile: String, basis: ReplyBasis) {
        self.name = name
        self.replyFile = replyFile
        self.basis = basis
    }
}

/// A provider's detector (plan HD-5, HD-7): fixed rules in code that turn one
/// failed tool run into an outcome. It reads the run's outputs and gives back
/// none of their text.
public protocol Detector: Sendable {
    var provider: Provider { get }
    /// The tool versions its rules were tested against.
    var testedToolVersions: [String] { get }
    var rules: [DetectorRule] { get }
    /// The outcome of `run`. `now` is when the run ended, for a reply that
    /// states its reset time relative to it.
    func outcome(of run: ToolRunRecord, at now: Date) -> RunOutcome
}

/// The lookup from a provider to its detector.
public enum Detectors {
    /// The login provider's detector; nil for an API token, which has no
    /// tool in this milestone.
    public static func detector(for provider: Provider) -> (any Detector)? {
        switch provider {
        case .claude: ClaudeDetector()
        case .codex: CodexDetector()
        case .gemini: AntigravityDetector()
        case .grok: GrokDetector()
        case .claudeApi, .openaiApi, .geminiApi, .grokApi, .openrouter: nil
        }
    }
}
