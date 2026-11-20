import Foundation

/// The detector for Grok Build's replies (plan HD-7, HD-8).
///
/// The runner reads Grok's output as plain text (PV-2), so the agent's
/// answer and the tool's own words are not told apart by any field: the
/// standard output is the agent's answer and is never read, so no task
/// text or tool output the agent repeats can fake a limit or a sign-out.
/// Only the standard error of a run that exited by itself with a status
/// other than 0 is read: a run that exited 0 gave an answer, whatever it
/// says. `grok -p` has never been run signed out (HD-8): the sign-out reply
/// puts "You are not authenticated.", which `grok models` printed on this
/// Mac, on standard error; if the real tool prints it on standard output,
/// the run reads as failed and the status command (`grok models`) finds
/// the sign-out. The limit and rate limit replies are invented.
public struct GrokDetector: Detector {
    public init() {}

    public var provider: Provider { .grok }
    public var testedToolVersions: [String] { [] }
    public var rules: [DetectorRule] {
        [
            DetectorRule(
                name: "a failed run saying \"You are not authenticated.\" on standard error is a sign-out",
                replyFile: "run-signed-out.json", basis: .madeFromObserved),
            DetectorRule(
                name: "a failed run naming a window's limit on standard error is a limit, with the time it states",
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
        guard run.endedByItself, !run.exitedZero else { return .failed }
        return ReplyReading.outcome(errorText: run.errorText, signedOutPhrases: Self.signedOutPhrases)
    }
}
