import Foundation

public enum ReplyBasis: String, CaseIterable, Sendable {
    case recordedNoLogin = "recorded_no_login"
    case invented
    case madeFromObserved = "made_from_observed"
}

public struct DetectorRule: Equatable, Sendable {
    public let name: String
    public let replyFile: String
    public let basis: ReplyBasis

    public init(name: String, replyFile: String, basis: ReplyBasis) {
        self.name = name
        self.replyFile = replyFile
        self.basis = basis
    }
}

public protocol Detector: Sendable {
    var provider: Provider { get }
    var testedToolVersions: [String] { get }
    var rules: [DetectorRule] { get }
    func outcome(of run: ToolRunRecord, at now: Date) -> RunOutcome
}

public enum Detectors {
    public static func detector(for provider: Provider) -> (any Detector)? { nil }
}
