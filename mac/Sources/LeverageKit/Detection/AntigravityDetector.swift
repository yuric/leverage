import Foundation

/// The detector for Antigravity's replies (plan HD-7, HD-8).
///
/// The runner asks for JSON output (PV-2): one object whose `status` is
/// `SUCCESS` and whose `response` is the agent's answer. Only a run that
/// did not succeed is read, and only its `error` field. No reply of a
/// signed-out, limited or rate-limited agy has been seen (L621): the
/// sign-out reply follows the observed shape of a successful one, and the
/// rest are invented.
public struct AntigravityDetector: Detector {
    public init() {}

    public var provider: Provider { .gemini }
    public var testedToolVersions: [String] { [] }
    public var rules: [DetectorRule] {
        [
            DetectorRule(
                name: "an error saying it is not signed in or not authenticated is a sign-out",
                replyFile: "run-signed-out.json", basis: .madeFromObserved),
            DetectorRule(
                name: "an error naming a window's limit or quota is a limit, with the time it states",
                replyFile: "run-limit-per-model.json", basis: .invented),
            DetectorRule(
                name: "an error with RESOURCE_EXHAUSTED or a rate limit and no window is a short rate limit",
                replyFile: "run-rate-limited.json", basis: .invented),
            DetectorRule(
                name: "any other error is a failure",
                replyFile: "run-failed.json", basis: .invented),
        ]
    }

    static let signedOutPhrases = ["not signed in", "not authenticated"]

    public func outcome(of run: ToolRunRecord, at now: Date) -> RunOutcome {
        guard run.endedByItself else { return .failed }
        guard let reply = ReplyReading.jsonObjects(in: run.outputText).last else {
            return run.exitedZero
                ? .failed
                : ReplyReading.outcome(
                    errorText: run.outputText + "\n" + run.errorText, signedOutPhrases: Self.signedOutPhrases)
        }
        if reply["status"] as? String == "SUCCESS" && run.exitedZero { return .failed }
        let error = reply["error"] as? String ?? ""
        let errorText = error.isEmpty ? run.errorText : error
        return ReplyReading.outcome(errorText: errorText, signedOutPhrases: Self.signedOutPhrases)
    }
}
