import Foundation
import Testing

@testable import LeverageKit

/// `RunEndReport`, the one line a runner prints on standard output when its
/// account stops (plan HD-6): version, kind, window, reset time, the task or
/// review id, the tool's version and the time observed, and nothing else.
@Suite("RunEndReport")
struct RunEndReportTests {
    private let taskID = UUID(uuidString: "0B4E5F60-1A2B-4C3D-8E9F-001122334455")!
    private let reviewID = UUID(uuidString: "7C8D9E0F-1A2B-4C3D-8E9F-665544332211")!
    private let observed = Date(timeIntervalSince1970: 1_795_000_000)
    private let reset = Date(timeIntervalSince1970: 1_795_003_600)

    private var limit: RunEndReport {
        RunEndReport(
            kind: .limit, window: .fiveHour, resetAt: reset, taskID: taskID, reviewID: nil,
            toolVersion: "0.0.1 (Claude Code stand-in)", observedAt: observed)
    }

    private var signedOut: RunEndReport {
        RunEndReport(
            kind: .signedOut, window: nil, resetAt: nil, taskID: nil, reviewID: reviewID,
            toolVersion: "codex-cli 0.0.1-standin", observedAt: observed)
    }

    /// The line as a JSON object, to change a key by hand.
    private func object(_ report: RunEndReport) throws -> [String: Any] {
        let line = try report.line()
        return try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }

    private func line(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    @Test("a limit and a sign-out each round-trip through their line")
    func roundTrip() throws {
        for report in [limit, signedOut] {
            let line = try report.line()
            #expect(!line.contains("\n"))
            #expect(try RunEndReport(line: line) == report)
        }
    }

    @Test("the line holds exactly the report's eight keys, in the contract's spelling")
    func keys() throws {
        #expect(Set(try object(limit).keys) == [
            "version", "kind", "window", "reset_at", "task_id", "review_id", "tool_version", "observed_at",
        ])
        let fields = try object(limit)
        #expect(fields["version"] as? Int == 1)
        #expect(fields["kind"] as? String == "limit")
        #expect(fields["window"] as? String == "five_hour")
        #expect(fields["task_id"] as? String == taskID.contractString)
        #expect(fields["review_id"] is NSNull)
        #expect(fields["reset_at"] as? String == "2026-11-18T12:06:40Z")
        #expect(try object(signedOut)["kind"] as? String == "signed_out")
    }

    @Test("a line with a key it does not know is refused")
    func unknownKey() throws {
        var fields = try object(limit)
        fields["message"] = "You've hit your limit"
        #expect(throws: RunEndReportError.unknownKey("message")) { try RunEndReport(line: try line(fields)) }
    }

    @Test("a line missing any one key is refused, even a key whose value may be null",
          arguments: ["version", "kind", "window", "reset_at", "task_id", "review_id", "tool_version", "observed_at"])
    func missingKey(key: String) throws {
        var fields = try object(limit)
        fields.removeValue(forKey: key)
        #expect(throws: (any Error).self) { try RunEndReport(line: try line(fields)) }
        // The same line with the key back is read.
        #expect(try RunEndReport(line: try line(object(limit))) == limit)
    }

    @Test("a line of another version is refused")
    func otherVersion() throws {
        var fields = try object(limit)
        fields["version"] = 2
        #expect(throws: (any Error).self) { try RunEndReport(line: try line(fields)) }
    }

    @Test("a limit names its window; a sign-out names neither a window nor a reset time")
    func kindsAndWindows() throws {
        var noWindow = try object(limit)
        noWindow["window"] = NSNull()
        #expect(throws: (any Error).self) { try RunEndReport(line: try line(noWindow)) }

        var signedOutWithWindow = try object(signedOut)
        signedOutWithWindow["window"] = "weekly"
        #expect(throws: (any Error).self) { try RunEndReport(line: try line(signedOutWithWindow)) }

        var signedOutWithReset = try object(signedOut)
        signedOutWithReset["reset_at"] = "2026-11-18T09:06:40Z"
        #expect(throws: (any Error).self) { try RunEndReport(line: try line(signedOutWithReset)) }

        var unknownWindow = try object(limit)
        unknownWindow["window"] = "daily"
        #expect(throws: (any Error).self) { try RunEndReport(line: try line(unknownWindow)) }

        // A limit whose reply stated no reset time is a report too (HD-7).
        var noReset = try object(limit)
        noReset["reset_at"] = NSNull()
        #expect(try RunEndReport(line: try line(noReset)).resetAt == nil)
    }

    @Test("a report names a task or a review, never both")
    func taskOrReview() throws {
        var both = try object(limit)
        both["review_id"] = reviewID.contractString
        #expect(throws: (any Error).self) { try RunEndReport(line: try line(both)) }
    }

    @Test("what is not one line of JSON is refused")
    func notALine() {
        #expect(throws: (any Error).self) { try RunEndReport(line: "") }
        #expect(throws: (any Error).self) { try RunEndReport(line: "You've hit your limit") }
        #expect(throws: (any Error).self) { try RunEndReport(line: "[]") }
    }

    @Test("the last line of the runner's standard output is the one read; blank lines around it are ignored")
    func lastLine() throws {
        let output = "\n" + (try signedOut.line()) + "\n\n"
        #expect(try RunEndReport(lastLineOf: Data(output.utf8)) == signedOut)
        #expect(throws: (any Error).self) { try RunEndReport(lastLineOf: Data()) }
    }
}
