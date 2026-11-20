import Foundation

/// The detector for Grok Build's replies (plan HD-7, HD-8).
///
/// The runner reads Grok's output as plain text (PV-2), so the agent's
/// answer and the tool's own words are not told apart by any field. Only a
/// run that exited with a status other than 0 is read: a run that exited 0
/// gave an answer, whatever it says. `grok -p` has never been run signed
/// out (HD-8): the sign-out reply follows "You are not authenticated.", which
/// `grok models` printed on this Mac, and the limit and rate limit replies
/// are invented.
public struct GrokDetector: Detector {
    public init() {}

    public var provider: Provider { .grok }
    public var testedToolVersions: [String] { [] }
    public var rules: [DetectorRule] {
        [
            DetectorRule(
                name: "a failed run saying \"You are not authenticated.\" is a sign-out",
                replyFile: "run-signed-out.json", basis: .madeFromObserved),
            DetectorRule(
                name: "a failed run naming a window's limit is a limit, with the time it states",
                replyFile: "run-limit-spend.json", basis: .invented),
            DetectorRule(
                name: "a failed run with a 429 or a rate limit and no window is a short rate limit",
                replyFile: "run-rate-limited.json", basis: .invented),
            DetectorRule(
                name: "a run that exited 0 is never read, whatever the answer says",
                replyFile: "run-failed.json", basis: .invented),
        ]
    }

    static let signedOutPhrases = ["you are not authenticated"]

    public func outcome(of run: ToolRunRecord, at now: Date) -> RunOutcome {
        guard run.endedBy == nil, !run.exitedZero else { return .failed }
        return ReplyReading.outcome(
            errorText: run.outputText + "\n" + run.errorText, signedOutPhrases: Self.signedOutPhrases)
    }
}
