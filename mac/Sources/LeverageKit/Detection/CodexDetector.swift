import Foundation

/// The detector for Codex's replies (plan HD-7, HD-8).
///
/// The runner asks for JSON lines (PV-2). Only the tool's own error events
/// are read: `error`, `turn.failed` and an item of type `error`; never an
/// agent message, so an answer that talks of a limit or of a 401 is never
/// taken for one. The sign-out wording was recorded from codex-cli 0.169.0
/// with no login; every limit and rate limit reply is invented, because
/// none has been seen, among them the structured field `limit` with
/// `window` and `resets_at` (seconds since 1970).
public struct CodexDetector: Detector {
    public init() {}

    public var provider: Provider { .codex }
    public var testedToolVersions: [String] { ["0.169.0"] }
    public var rules: [DetectorRule] {
        [
            DetectorRule(
                name: "an error event with 401 Unauthorized is a sign-out",
                replyFile: "run-signed-out.json", basis: .recordedNoLogin),
            DetectorRule(
                name: "an error event whose limit field names a window is a limit, with its resets_at",
                replyFile: "run-limit-five-hour.json", basis: .invented),
            DetectorRule(
                name: "an error event naming a window's limit in words is a limit; no time stated, no reset",
                replyFile: "run-limit-weekly-text.json", basis: .invented),
            DetectorRule(
                name: "an error event with a 429 or a rate limit and no window is a short rate limit",
                replyFile: "run-rate-limited.json", basis: .invented),
            DetectorRule(
                name: "any other error is a failure, and an agent message is never read",
                replyFile: "run-failed.json", basis: .invented),
        ]
    }

    static let signedOutPhrases = ["401 unauthorized"]

    public func outcome(of run: ToolRunRecord, at now: Date) -> RunOutcome {
        guard run.endedByItself else { return .failed }
        let events = ReplyReading.jsonObjects(in: run.outputText)
        guard !events.isEmpty else {
            return run.exitedZero
                ? .failed
                : ReplyReading.outcome(
                    errorText: run.outputText + "\n" + run.errorText, signedOutPhrases: Self.signedOutPhrases)
        }
        // Codex prints error events while it reconnects, also in a run that
        // then succeeds (replies/codex/run-signed-out.json shows them): a run
        // that exited 0 with no failed turn is never read.
        let turnFailed = events.contains { $0["type"] as? String == "turn.failed" }
        if run.exitedZero && !turnFailed { return .failed }
        var messages: [String] = []
        var window: String?
        var reset: Date?
        for event in events {
            switch event["type"] as? String {
            case "error":
                if let message = event["message"] as? String { messages.append(message) }
                if let limit = event["limit"] as? [String: Any] {
                    window = window ?? limit["window"] as? String
                    reset = reset ?? ReplyReading.time(fromSeconds: limit["resets_at"])
                }
            case "turn.failed":
                if let message = (event["error"] as? [String: Any])?["message"] as? String {
                    messages.append(message)
                }
            case "item.completed":
                if let item = event["item"] as? [String: Any], item["type"] as? String == "error",
                    let message = item["message"] as? String
                {
                    messages.append(message)
                }
            default:
                break
            }
        }
        if messages.isEmpty && window == nil {
            return .failed
        }
        return ReplyReading.outcome(
            errorText: messages.joined(separator: "\n"), signedOutPhrases: Self.signedOutPhrases,
            structuredWindow: window, structuredReset: reset)
    }
}
