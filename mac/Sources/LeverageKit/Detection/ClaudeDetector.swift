import Foundation

/// The detector for Claude Code's replies (plan HD-7, HD-8).
///
/// The runner asks for JSON output (PV-2): one result object whose `result`
/// is the agent's answer, or, when `is_error` is true, the tool's own error
/// text. Only that error text is read, so an answer that talks of a limit
/// or of being logged out is never taken for one. The sign-out wording was
/// recorded from Claude Code 2.1.325 with no login; every limit and rate
/// limit reply is invented, because none has been seen.
public struct ClaudeDetector: Detector {
    public init() {}

    public var provider: Provider { .claude }
    public var testedToolVersions: [String] { ["2.1.325"] }
    public var rules: [DetectorRule] {
        [
            DetectorRule(
                name: "an error result saying it is not logged in is a sign-out",
                replyFile: "run-signed-out.json", basis: .recordedNoLogin),
            DetectorRule(
                name: "an error result naming a window's limit is a limit, with the time it states",
                replyFile: "run-limit-five-hour.json", basis: .invented),
            DetectorRule(
                name: "a limit that states no time has no reset time",
                replyFile: "run-limit-weekly-no-reset.json", basis: .invented),
            DetectorRule(
                name: "an error result with a 429 or a rate limit and no window is a short rate limit",
                replyFile: "run-rate-limited.json", basis: .invented),
            DetectorRule(
                name: "any other error result is a failure",
                replyFile: "run-failed.json", basis: .invented),
            DetectorRule(
                name: "a result that is no error is never read, whatever the answer says",
                replyFile: "run-answer-names-a-limit.json", basis: .invented),
        ]
    }

    static let signedOutPhrases = ["not logged in", "please run /login"]

    public func outcome(of run: ToolRunRecord, at now: Date) -> RunOutcome {
        guard run.endedByItself else { return .failed }
        let result = ReplyReading.jsonObjects(in: run.outputText).last { $0["type"] as? String == "result" }
        let errorText: String
        if let result {
            if result["is_error"] as? Bool == true {
                errorText = result["result"] as? String ?? ""
            } else if run.exitedZero {
                return .failed
            } else {
                errorText = run.errorText
            }
        } else {
            guard !run.exitedZero else { return .failed }
            errorText = run.outputText + "\n" + run.errorText
        }
        return ReplyReading.outcome(errorText: errorText, signedOutPhrases: Self.signedOutPhrases)
    }
}
