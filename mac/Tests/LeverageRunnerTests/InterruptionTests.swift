import Foundation
import LeverageKit
import LeverageTestSupport
import Testing

@testable import LeverageRunner

/// A reply file under `mac/Tests/StandIns/replies/` as a failed run's record
/// (plan HD-8): the outputs and exit status the stand-ins play, with the
/// reset time filled in.
struct ReplyFile {
    let record: ToolRunRecord
    /// The made-up `LVRG-REPLY-…` marker somewhere in the outputs: a log
    /// line or a report line that holds it holds the tool's text.
    let marker: String
    let expectedWindow: LimitWindow?
    let statesReset: Bool

    init(_ provider: String, _ name: String, resetAt: Date = ReplyFile.resetAt) throws {
        let url = StandIns.replies.appendingPathComponent(provider).appendingPathComponent(name)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let meta = try #require(object["meta"] as? [String: Any])
        let iso = ISO8601DateFormatter().string(from: resetAt)
        let epoch = String(Int(resetAt.timeIntervalSince1970))
        func filled(_ key: String) throws -> Data {
            let text = try #require(object[key] as? String)
            return Data(text.replacingOccurrences(of: "@RESET_AT_ISO@", with: iso)
                .replacingOccurrences(of: "\"@RESET_AT_EPOCH@\"", with: epoch).utf8)
        }
        let status = try #require(object["exit_status"] as? Int)
        record = ToolRunRecord(
            termination: .exited(Int32(status)), standardOutput: try filled("stdout"),
            standardError: try filled("stderr"))
        marker = try #require(meta["marker"] as? String)
        expectedWindow = (meta["expect_window"] as? String).flatMap(LimitWindow.init(rawValue:))
        statesReset = meta["expect_reset"] as? String == "stated"
    }

    /// A reset time on a whole second, as the replies state it.
    static let resetAt = Date(timeIntervalSince1970: 1_900_000_000)
}

/// Counts the status questions and answers them as told.
final class StatusAnswers: @unchecked Sendable {
    private let lock = NSLock()
    private var asked = 0
    private let answer: SignInAnswer

    init(_ answer: SignInAnswer) { self.answer = answer }

    var count: Int { lock.withLock { asked } }
    var check: @Sendable () async -> SignInAnswer {
        { [self] in
            lock.withLock { asked += 1 }
            return answer
        }
    }
}

/// HD-5 to HD-7, HM-19: a failed run of a seat with a credential is read by
/// its provider's detector; a short rate limit is retried in place three
/// times; a run the output does not settle asks the status command; a run
/// with no credential detects nothing.
@Suite("Interruption", .timeLimit(.minutes(Patience.minutes(2))))
struct InterruptionTests {
    static let noWaits: [Duration] = [.zero, .zero, .zero]

    func interruption(
        _ provider: Provider = .claude, credential: Bool = true, status: StatusAnswers = StatusAnswers(.signedIn)
    ) -> Interruption {
        Interruption(provider: provider, hasCredential: credential, waits: Self.noWaits, signInStatus: status.check)
    }

    // MARK: One failed run

    struct LimitCase: Sendable, CustomTestStringConvertible {
        let folder: String
        let provider: Provider
        let file: String
        var testDescription: String { "\(folder)/\(file)" }
    }

    static let limits = [
        LimitCase(folder: "claude", provider: .claude, file: "run-limit-five-hour.json"),
        LimitCase(folder: "claude", provider: .claude, file: "run-limit-weekly-no-reset.json"),
        LimitCase(folder: "codex", provider: .codex, file: "run-limit-five-hour.json"),
        LimitCase(folder: "codex", provider: .codex, file: "run-limit-weekly-text.json"),
        LimitCase(folder: "gemini", provider: .gemini, file: "run-limit-per-model.json"),
        LimitCase(folder: "grok", provider: .grok, file: "run-limit-spend.json"),
    ]

    @Test("a limit reply stops the account with its window and the reset time it states", arguments: limits)
    func limit(test: LimitCase) async throws {
        let reply = try ReplyFile(test.folder, test.file)
        let status = StatusAnswers(.signedIn)
        let window = try #require(reply.expectedWindow)
        let decision = await interruption(test.provider, status: status).decide(after: reply.record, at: Date())
        #expect(decision == .accountStopped(.limit(window: window, resetAt: reply.statesReset ? ReplyFile.resetAt : nil)))
        #expect(status.count == 0, "the output settled it: no status question")
    }

    @Test("a sign-out reply stops the account as signed out",
          arguments: [(Provider.claude, "claude"), (.codex, "codex"), (.gemini, "gemini"), (.grok, "grok")])
    func signedOutReply(provider: Provider, folder: String) async throws {
        let reply = try ReplyFile(folder, "run-signed-out.json")
        let status = StatusAnswers(.signedIn)
        #expect(await interruption(provider, status: status).decide(after: reply.record, at: Date())
            == .accountStopped(.signedOut))
        #expect(status.count == 0)
    }

    @Test("a short rate limit is retried in place",
          arguments: [(Provider.claude, "claude"), (.codex, "codex"), (.gemini, "gemini"), (.grok, "grok")])
    func rateLimited(provider: Provider, folder: String) async throws {
        let reply = try ReplyFile(folder, "run-rate-limited.json")
        let status = StatusAnswers(.signedOut)
        #expect(await interruption(provider, status: status).decide(after: reply.record, at: Date()) == .retryInPlace)
        #expect(status.count == 0)
    }

    @Test("a failure the output does not settle is a sign-out when the status says signed out")
    func failedThenSignedOut() async throws {
        let reply = try ReplyFile("claude", "run-failed.json")
        let status = StatusAnswers(.signedOut)
        #expect(await interruption(status: status).decide(after: reply.record, at: Date())
            == .accountStopped(.signedOut))
        #expect(status.count == 1)
    }

    @Test("a failure the output does not settle goes on as before when the status says signed in, or has none",
          arguments: [SignInAnswer.signedIn, .noStatusCommand])
    func failedThenSignedIn(answer: SignInAnswer) async throws {
        let reply = try ReplyFile("claude", "run-failed.json")
        let status = StatusAnswers(answer)
        #expect(await interruption(status: status).decide(after: reply.record, at: Date()) == .goOnAsBefore)
        #expect(status.count == 1)
    }

    @Test("a failure the output does not settle goes on as before when the status command could not tell (CL-22)")
    func failedThenCouldNotTell() async throws {
        let reply = try ReplyFile("claude", "run-failed.json")
        let status = StatusAnswers(.couldNotTell)
        #expect(await interruption(status: status).decide(after: reply.record, at: Date()) == .goOnAsBefore)
        #expect(status.count == 1)
    }

    @Test("an answer that names a limit is not a limit")
    func answerNamesALimit() async throws {
        let reply = try ReplyFile("claude", "run-answer-names-a-limit.json")
        #expect(await interruption().decide(after: reply.record, at: Date()) == .goOnAsBefore)
    }

    @Test("with no credential nothing is detected and nothing is asked (HM-19)",
          arguments: ["run-limit-five-hour.json", "run-signed-out.json", "run-rate-limited.json", "run-failed.json"])
    func noCredential(file: String) async throws {
        let reply = try ReplyFile("claude", file)
        let status = StatusAnswers(.signedOut)
        #expect(await interruption(credential: false, status: status).decide(after: reply.record, at: Date())
            == .goOnAsBefore)
        #expect(status.count == 0)
    }

    // MARK: The retry in place

    /// A tool whose runs answer in turn: each a reply file or an answer.
    final class Attempts: @unchecked Sendable {
        private let lock = NSLock()
        private var runs: [ToolRun]
        private var made = 0

        init(_ runs: [ToolRun]) { self.runs = runs }
        var count: Int { lock.withLock { made } }
        var attempt: @Sendable () async throws -> ToolRun {
            { [self] in
                lock.withLock {
                    made += 1
                    return runs.isEmpty ? .answered(ToolAnswer(text: "spare", tokens: 0)) : runs.removeFirst()
                }
            }
        }
    }

    static let answer = ToolAnswer(text: "LEVERAGE-EVIDENCE: proof.txt", tokens: 3)

    func failed(_ file: String, _ folder: String = "claude") throws -> ToolRun {
        .failed(.exited(1), try ReplyFile(folder, file).record)
    }

    @Test("a short rate limit is retried three times; an answer on the third retry is the answer")
    func retriedThenAnswered() async throws {
        let attempts = Attempts([
            try failed("run-rate-limited.json"), try failed("run-rate-limited.json"),
            try failed("run-rate-limited.json"), .answered(Self.answer),
        ])
        let result = try await interruption().run(for: .task(UUID()), attempts.attempt)
        #expect(result == .answered(Self.answer))
        #expect(attempts.count == 4)
    }

    @Test("a short rate limit that is still there after three retries is a failure (CL-22)")
    func retriedThenFailed() async throws {
        let attempts = Attempts(Array(repeating: try failed("run-rate-limited.json"), count: 5))
        let status = StatusAnswers(.signedOut)
        let result = try await interruption(status: status).run(for: .task(UUID()), attempts.attempt)
        #expect(result == .failed(.exited(1)))
        #expect(attempts.count == 4, "one run and three retries")
        #expect(status.count == 0, "a rate limit is not a sign-out")
    }

    @Test("the waits before the three retries are 5, 15 and 45 seconds (HD-7)")
    func waits() {
        #expect(Interruption.rateLimitWaits == [.seconds(5), .seconds(15), .seconds(45)])
        #expect(Interruption(provider: .codex, hasCredential: true).waits == Interruption.rateLimitWaits)
    }

    @Test("a retry that meets a limit stops the account, with the report of the work")
    func retriedThenLimit() async throws {
        let taskID = UUID()
        let attempts = Attempts([try failed("run-rate-limited.json"), try failed("run-limit-five-hour.json")])
        let before = Date()
        let result = try await interruption().run(for: .task(taskID), attempts.attempt)
        guard case .accountStopped(let report) = result else {
            Issue.record("expected the account to stop, got \(result)")
            return
        }
        #expect(report.kind == .limit)
        #expect(report.window == .fiveHour)
        #expect(report.resetAt == ReplyFile.resetAt)
        #expect(report.taskID == taskID)
        #expect(report.reviewID == nil)
        #expect(report.observedAt >= before.addingTimeInterval(-1))
    }

    @Test("a sign-out of a review names the review")
    func signedOutReview() async throws {
        let reviewID = UUID()
        let attempts = Attempts([try failed("run-signed-out.json", "codex")])
        let result = try await interruption(.codex).run(for: .review(reviewID), attempts.attempt)
        guard case .accountStopped(let report) = result else {
            Issue.record("expected the account to stop, got \(result)")
            return
        }
        #expect(report.kind == .signedOut)
        #expect(report.window == nil && report.resetAt == nil)
        #expect(report.reviewID == reviewID && report.taskID == nil)
    }

    @Test("with no credential a rate limit is not retried and a limit is a failure")
    func noCredentialRun() async throws {
        let rate = Attempts([try failed("run-rate-limited.json")])
        #expect(try await interruption(credential: false).run(for: .task(UUID()), rate.attempt) == .failed(.exited(1)))
        #expect(rate.count == 1)
        let limit = Attempts([try failed("run-limit-five-hour.json")])
        #expect(try await interruption(credential: false).run(for: .task(UUID()), limit.attempt) == .failed(.exited(1)))
    }

    @Test("a tool that did not start is a failure, with no detector and no status question")
    func didNotStart() async throws {
        let status = StatusAnswers(.signedOut)
        let attempts = Attempts([.failed(.couldNotStart("the program is missing or cannot be run"), nil)])
        let result = try await interruption(status: status).run(for: .task(UUID()), attempts.attempt)
        #expect(result == .failed(.couldNotStart("the program is missing or cannot be run")))
        #expect(status.count == 0)
    }
}
