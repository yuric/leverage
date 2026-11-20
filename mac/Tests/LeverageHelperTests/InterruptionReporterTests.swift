import Foundation
import LeverageKit
import LeverageTestSupport
import Testing

@testable import LeverageHelper

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// What the helper sends when a run ends because its account stopped (plan
/// HD-6, HD-10): the runner exits with code 5 and prints one `RunEndReport`
/// line on standard output; the helper sends `report_limit` or
/// `report_signed_out` and nothing else, under one key that a retry repeats.
/// A refusal is logged and followed by one run-stopped report with the
/// matching reason. A code 5 with no readable line is code 4.
@Suite("Interruption reporter", .timeLimit(.minutes(Patience.minutes(1))))
struct InterruptionReporterTests {
    private let seat = UUID()
    private let credential = UUID()
    private let task = UUID()
    private let review = UUID()
    private let observed = Date(timeIntervalSince1970: 1_800_000_000)
    private let reset = Date(timeIntervalSince1970: 1_800_003_600)

    private func limitLine(window: LimitWindow = .fiveHour, resetAt: Date? = nil, review: Bool = false,
                           toolVersion: String? = "9.9.9 (made-up tool)") -> RunEndReport {
        RunEndReport(
            kind: .limit, window: window, resetAt: resetAt,
            taskID: review ? nil : task, reviewID: review ? self.review : nil,
            toolVersion: toolVersion, observedAt: observed)
    }

    private func signOutLine(review: Bool = false) -> RunEndReport {
        RunEndReport(
            kind: .signedOut, window: nil, resetAt: nil,
            taskID: review ? nil : task, reviewID: review ? self.review : nil,
            toolVersion: "9.9.9 (made-up tool)", observedAt: observed)
    }

    private func reporter(_ rig: HelperRig, log: Log = quietLog) -> InterruptionReporter {
        InterruptionReporter(api: rig.api, timings: fastTimings, log: log)
    }

    // MARK: The reports

    @Test("a limit line sends report_limit with the window, the reset time and the tool's version, and nothing else")
    func limitSendsReportLimit() async throws {
        let rig = try HelperRig()

        let result = await reporter(rig).report(
            limitLine(resetAt: reset), seatID: seat, credentialID: credential, toolVersion: "1.0 (located)")

        #expect(result == .reported)
        #expect(rig.api.calls.map(\.operation) == [.reportLimit])
        let call = try #require(rig.calls(.reportLimit).first)
        #expect(call.path["id"] == credential.contractString)
        #expect(call.key != nil)
        let body = try #require(call.body)
        #expect(body["credential_id"]?.stringValue == credential.contractString)
        #expect(body["seat_id"]?.stringValue == seat.contractString)
        #expect(body["task_id"]?.stringValue == task.contractString)
        #expect(body["review_id"] == .null)
        #expect(body["job_id"] == .null)
        #expect(body["window"]?.stringValue == "five_hour")
        #expect(body["reset_at"]?.stringValue == LeverageJSON.string(from: reset))
        #expect(body["observed_at"]?.stringValue == LeverageJSON.string(from: observed))
        // The runner's version of the tool, which saw the limit, wins.
        #expect(body["tool_version"]?.stringValue == "9.9.9 (made-up tool)")
    }

    @Test("a limit with no reset time sends reset_at as null")
    func limitWithNoResetTime() async throws {
        let rig = try HelperRig()

        let result = await reporter(rig).report(
            limitLine(window: .weekly, resetAt: nil, review: true), seatID: seat, credentialID: credential,
            toolVersion: nil)

        #expect(result == .reported)
        let body = try #require(rig.calls(.reportLimit).first?.body)
        #expect(body["reset_at"] == .null)
        #expect(body["window"]?.stringValue == "weekly")
        #expect(body["review_id"]?.stringValue == review.contractString)
        #expect(body["task_id"] == .null)
    }

    @Test("a sign-out line sends report_signed_out, with no window and no reset time, and nothing else")
    func signOutSendsReportSignedOut() async throws {
        let rig = try HelperRig()

        let result = await reporter(rig).report(
            signOutLine(review: true), seatID: seat, credentialID: credential, toolVersion: nil)

        #expect(result == .reported)
        #expect(rig.api.calls.map(\.operation) == [.reportSignedOut])
        let call = try #require(rig.calls(.reportSignedOut).first)
        #expect(call.path["id"] == credential.contractString)
        let body = try #require(call.body)
        #expect(body["review_id"]?.stringValue == review.contractString)
        #expect(body["seat_id"]?.stringValue == seat.contractString)
        #expect(body["window"] == nil)
        #expect(body["reset_at"] == nil)
        #expect(body["tool_version"]?.stringValue == "9.9.9 (made-up tool)")
    }

    @Test("a line with no tool version takes the version the helper found when it started the run")
    func toolVersionFallsBack() async throws {
        let rig = try HelperRig()

        _ = await reporter(rig).report(
            limitLine(toolVersion: nil), seatID: seat, credentialID: credential, toolVersion: "1.0 (located)")

        #expect(rig.calls(.reportLimit).first?.body?["tool_version"]?.stringValue == "1.0 (located)")
    }

    // MARK: Refused

    @Test(
        "a refused report is logged with its code and followed by one run-stopped report with the matching reason",
        arguments: [RunEndReport.Kind.limit, .signedOut])
    func refusalThenRunStopped(kind: RunEndReport.Kind) async throws {
        let rig = try HelperRig()
        rig.api.script {
            $0.reportLimit = { _, _, key in
                .refused(Refusal(code: .invalidState, ruleID: nil, reason: nil), key: key.value, command: .reportLimit)
            }
            $0.reportSignedOut = { _, _, key in
                .refused(
                    Refusal(code: .invalidState, ruleID: nil, reason: nil), key: key.value, command: .reportSignedOut)
            }
        }
        let captured = CapturedLog()
        let line = kind == .limit ? limitLine() : signOutLine()

        let result = await reporter(rig, log: captured.log).report(
            line, seatID: seat, credentialID: credential, toolVersion: nil)

        #expect(result == .refusedThenStopped)
        let reportOperation: ContractOperation = kind == .limit ? .reportLimit : .reportSignedOut
        #expect(rig.api.calls.map(\.operation) == [reportOperation, .reportRunStopped])
        let stopped = try #require(rig.calls(.reportRunStopped).first)
        #expect(stopped.path["id"] == seat.contractString)
        #expect(stopped.body?["credential_id"]?.stringValue == credential.contractString)
        #expect(stopped.body?["stop_reason"]?.stringValue == (kind == .limit ? "limit" : "signed_out"))
        #expect(captured.text.contains("invalid_state"))
    }

    @Test("an answer the server gave that is not a refusal (404) is handled like a refusal")
    func notFoundThenRunStopped() async throws {
        let rig = try HelperRig()
        rig.api.script {
            $0.reportLimit = { _, _, _ in throw TransportError(code: .notFound, message: "made up") }
        }

        let result = await reporter(rig).report(limitLine(), seatID: seat, credentialID: credential, toolVersion: nil)

        #expect(result == .refusedThenStopped)
        #expect(rig.calls(.reportLimit).count == 1)
        #expect(rig.calls(.reportRunStopped).first?.body?["stop_reason"]?.stringValue == "limit")
    }

    // MARK: Transport failures

    @Test("a transport failure sends the same report again with the same key")
    func transportFailureRepeatsTheKey() async throws {
        let rig = try HelperRig()
        let failures = Counter()
        rig.api.script {
            $0.reportLimit = { _, _, key in
                if failures.next() <= 2 { throw URLError(.networkConnectionLost) }
                return .completed(.object([:]), key: key.value, command: .reportLimit)
            }
        }

        let result = await reporter(rig).report(limitLine(), seatID: seat, credentialID: credential, toolVersion: nil)

        #expect(result == .reported)
        let sends = rig.calls(.reportLimit)
        #expect(sends.count == 3)
        #expect(Set(sends.compactMap(\.key)).count == 1)
        #expect(sends.allSatisfy { $0.key != nil })
        #expect(rig.calls(.reportRunStopped).isEmpty)
    }

    @Test("a server error (5xx) is sent again with the same key too")
    func serverErrorRepeatsTheKey() async throws {
        let rig = try HelperRig()
        let failures = Counter()
        rig.api.script {
            $0.reportSignedOut = { _, _, key in
                if failures.next() == 1 { throw LeverageClientError.unexpectedStatus(503) }
                return .completed(.object([:]), key: key.value, command: .reportSignedOut)
            }
        }

        let result = await reporter(rig).report(signOutLine(), seatID: seat, credentialID: credential, toolVersion: nil)

        #expect(result == .reported)
        let sends = rig.calls(.reportSignedOut)
        #expect(sends.count == 2)
        #expect(Set(sends.compactMap(\.key)).count == 1)
    }

    // MARK: No work named

    @Test("a line that names no task and no review cannot be a report: the run's end is reported with its reason")
    func noWorkThenRunStopped() async throws {
        let rig = try HelperRig()
        let line = RunEndReport(
            kind: .signedOut, window: nil, resetAt: nil, taskID: nil, reviewID: nil, toolVersion: nil,
            observedAt: observed)

        let result = await reporter(rig).report(line, seatID: seat, credentialID: credential, toolVersion: nil)

        #expect(result == .noWorkThenStopped)
        #expect(rig.api.calls.map(\.operation) == [.reportRunStopped])
        #expect(rig.calls(.reportRunStopped).first?.body?["stop_reason"]?.stringValue == "signed_out")
    }

    // MARK: Through the launcher

    /// A runner program that prints `stdout` on standard output, a line on
    /// standard error, and exits with `code`.
    private func scriptedRunner(_ rig: HelperRig, stdout: String, code: Int32) throws -> URL {
        let script = rig.folder.url.appendingPathComponent("scripted-runner-\(UUID().uuidString).sh")
        let quoted = stdout.replacingOccurrences(of: "'", with: "'\\''")
        try Data("""
            #!/bin/sh
            printf '%s' '\(quoted)'
            echo "scripted runner: a line of the runner's own log" >&2
            exit \(code)

            """.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    private func start(_ rig: HelperRig, runner: URL, seat: UUID, credential: UUID) async throws -> Launcher {
        rig.settings.runnerPath = runner.path
        _ = try rig.folders.createFresh(for: credential)
        let launcher = rig.launcher()
        let result = await launcher.start(helperRequest(
            .startSeat, seat: seat, credential: credential,
            params: .init(provider: .claude, role: .builder, taskID: task)))
        #expect(result.outcome == .finished)
        return launcher
    }

    @Test("code 5 with a limit line: report_limit is sent, and no run-stopped report")
    func codeFiveWithLimitLine() async throws {
        let rig = try HelperRig()
        let line = try limitLine(resetAt: reset).line()
        let runner = try scriptedRunner(rig, stdout: "\(line)\n", code: 5)

        let launcher = try await start(rig, runner: runner, seat: seat, credential: credential)

        #expect(await eventually { !rig.calls(.reportLimit).isEmpty })
        try await Task.sleep(for: .milliseconds(300))
        #expect(await launcher.runningSeats().isEmpty)
        let call = try #require(rig.calls(.reportLimit).first)
        #expect(call.path["id"] == credential.contractString)
        #expect(call.body?["seat_id"]?.stringValue == seat.contractString)
        #expect(call.body?["window"]?.stringValue == "five_hour")
        #expect(rig.calls(.reportLimit).count == 1)
        #expect(rig.calls(.reportRunStopped).isEmpty)
        #expect(rig.calls(.reportSignedOut).isEmpty)
    }

    @Test("code 5 with a sign-out line: report_signed_out is sent, and no run-stopped report")
    func codeFiveWithSignOutLine() async throws {
        let rig = try HelperRig()
        let line = try signOutLine().line()
        let runner = try scriptedRunner(rig, stdout: "\(line)\n", code: 5)

        _ = try await start(rig, runner: runner, seat: seat, credential: credential)

        #expect(await eventually { !rig.calls(.reportSignedOut).isEmpty })
        try await Task.sleep(for: .milliseconds(300))
        #expect(rig.calls(.reportSignedOut).count == 1)
        #expect(rig.calls(.reportRunStopped).isEmpty)
        #expect(rig.calls(.reportLimit).isEmpty)
    }

    @Test(
        "code 5 with no readable line is handled as code 4: the run is reported stopped with an error",
        arguments: ["", "not a report line\n", "{\"version\":1}\n"])
    func codeFiveWithNoLine(stdout: String) async throws {
        let rig = try HelperRig()
        let runner = try scriptedRunner(rig, stdout: stdout, code: 5)

        _ = try await start(rig, runner: runner, seat: seat, credential: credential)

        #expect(await eventually { !rig.calls(.reportRunStopped).isEmpty })
        let stopped = try #require(rig.calls(.reportRunStopped).first)
        #expect(stopped.body?["stop_reason"]?.stringValue == "error")
        #expect(rig.calls(.reportLimit).isEmpty)
        #expect(rig.calls(.reportSignedOut).isEmpty)
    }

    @Test("a refused report after code 5 is followed by one run-stopped report with the matching reason")
    func codeFiveRefused() async throws {
        let rig = try HelperRig()
        rig.api.script {
            $0.reportLimit = { _, _, key in
                .refused(Refusal(code: .invalidState, ruleID: nil, reason: nil), key: key.value, command: .reportLimit)
            }
        }
        let line = try limitLine().line()
        let runner = try scriptedRunner(rig, stdout: "\(line)\n", code: 5)

        _ = try await start(rig, runner: runner, seat: seat, credential: credential)

        #expect(await eventually { !rig.calls(.reportRunStopped).isEmpty })
        try await Task.sleep(for: .milliseconds(300))
        #expect(rig.calls(.reportRunStopped).count == 1)
        #expect(rig.calls(.reportRunStopped).first?.body?["stop_reason"]?.stringValue == "limit")
    }

    @Test("a report line in the runner's log would be a copy: the runner's standard output never reaches the log")
    func reportLineNotInLog() async throws {
        let rig = try HelperRig()
        let line = try limitLine().line()
        let runner = try scriptedRunner(rig, stdout: "\(line)\n", code: 5)

        let launcher = try await start(rig, runner: runner, seat: seat, credential: credential)

        #expect(await eventually { !rig.calls(.reportLimit).isEmpty })
        let log = try String(contentsOf: launcher.logFile(for: seat), encoding: .utf8)
        #expect(log.contains("a line of the runner's own log"))
        #expect(!log.contains("five_hour"))
        #expect(!log.contains(task.contractString))
    }
}

/// Counts calls from any task.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    /// 1 for the first call, 2 for the second, and so on.
    func next() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }
}
