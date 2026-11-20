import Foundation
import LeverageKit
import LeverageTestSupport
import Testing

@testable import LeverageAppServices

/// An owner API that answers `issue_helper_token` with the next token of a
/// list; nil stands for a repeated answer, which carries none.
private func issuer(_ tokens: [String?]) -> FakeOwnerAPI {
    let fake = FakeOwnerAPI()
    let next = Locked(0)
    fake.script { answers in
        answers.issueHelperToken = { _, key in
            let index = next.update { value -> Int in
                defer { value += 1 }
                return value
            }
            let helperID = UUID()
            let token: String? = index < tokens.count ? tokens[index] : "lvh_made-up-extra-\(index)"
            let answer: HelperTokenAnswer = token.map {
                .shown(HelperTokenIssued(helperID: helperID, helperToken: $0))
            } ?? .repeated(HelperTokenIssuedRepeated(helperID: helperID))
            return .completed(answer, key: key.value, command: .issueHelperToken)
        }
    }
    return fake
}

/// The app's environment as a test gives it: the five names the helper may
/// have, and others it must not get.
private let parentEnvironment = [
    "HOME": "/Users/someone-made-up",
    "PATH": "/usr/bin:/bin",
    "TMPDIR": "/tmp/made-up/",
    "LANG": "en_US.UTF-8",
    "USER": "someone-made-up",
    "SECRET_OF_THE_APP": "made-up-secret-value",
    "LEVERAGE_SEAT_TOKEN": "lvs_made-up-must-not-pass",
    "LEVERAGE_COMPOSE_PROJECT": "made-up-project",
]

private let apiURL = URL(string: "http://127.0.0.1:47130")!

@Suite("HelperSupervisor")
struct HelperSupervisorTests {
    private func supervisor(
        _ fake: FakeHelperProgram, now: @escaping @Sendable () -> Date = { Date() }
    ) -> HelperSupervisor {
        var configuration = HelperSupervisor.Configuration(
            helperProgram: fake.program, supportFolder: fake.support, environment: parentEnvironment)
        configuration.restartDelay = .zero
        configuration.stopGracePeriod = Patience.scaled(.seconds(5))
        return HelperSupervisor(configuration: configuration, now: now, log: Log(component: "test", write: { _ in }))
    }

    @Test("issues the token with the helper's name, and starts the helper with it in its environment only")
    func startsWithTokenInEnvironment() async throws {
        let fake = try FakeHelperProgram(exitCodes: [])
        let owner = issuer(["lvh_made-up-first"])
        let helper = supervisor(fake)

        #expect(await helper.start(apiBaseURL: apiURL, issuer: owner) == .running)
        #expect(await eventually { fake.runs == 1 && !fake.environment(ofRun: 1).isEmpty })

        #expect(owner.calls.map(\.operation) == [.issueHelperToken])
        #expect(owner.calls.first?.body == .object(["name": .string("This Mac")]))
        #expect(owner.calls.first?.key != nil)

        #expect(fake.environment(ofRun: 1) == [
            "HOME": "/Users/someone-made-up",
            "PATH": "/usr/bin:/bin",
            "TMPDIR": "/tmp/made-up/",
            "LANG": "en_US.UTF-8",
            "USER": "someone-made-up",
            "LEVERAGE_API_URL": "http://127.0.0.1:47130",
            "LEVERAGE_HELPER_TOKEN": "lvh_made-up-first",
            "LEVERAGE_SUPPORT_DIR": fake.support.path,
        ])
        #expect(!fake.arguments(ofRun: 1).contains("lvh_made-up"))

        await helper.stop()
        // The token is in no file of the support folder (the helper's log
        // included) and the log has what the helper wrote.
        let files = textOfEveryFile(under: fake.support)
        #expect(files.values.allSatisfy { !$0.contains("lvh_made-up") })
        #expect(files["logs/helper.log"]?.contains("fake helper run 1") == true)
        await fake.expectNothingLeft()
    }

    @Test("a repeated answer has no token, so the token is issued again with a new key")
    func repeatedAnswerIssuesAgain() async throws {
        let fake = try FakeHelperProgram(exitCodes: [])
        let owner = issuer([nil, "lvh_made-up-second"])
        let helper = supervisor(fake)

        #expect(await helper.start(apiBaseURL: apiURL, issuer: owner) == .running)
        #expect(await eventually { !fake.environment(ofRun: 1).isEmpty })
        let keys = owner.calls.compactMap(\.key)
        #expect(keys.count == 2)
        #expect(Set(keys).count == 2)
        #expect(fake.environment(ofRun: 1)["LEVERAGE_HELPER_TOKEN"] == "lvh_made-up-second")
        await helper.stop()
        await fake.expectNothingLeft()
    }

    @Test("exit code 3: a new token with a new key, and the helper started again")
    func restartsOnExitCode3() async throws {
        let fake = try FakeHelperProgram(exitCodes: [3])
        let owner = issuer(["lvh_made-up-1", "lvh_made-up-2"])
        let helper = supervisor(fake)

        _ = await helper.start(apiBaseURL: apiURL, issuer: owner)
        #expect(await eventually { fake.runs == 2 && !fake.environment(ofRun: 2).isEmpty })
        #expect(await eventually { await helper.state() == .running })
        #expect(fake.environment(ofRun: 2)["LEVERAGE_HELPER_TOKEN"] == "lvh_made-up-2")
        let keys = owner.calls.compactMap(\.key)
        #expect(keys.count == 2)
        #expect(Set(keys).count == 2)
        await helper.stop()
        await fake.expectNothingLeft()
    }

    @Test("restarted at most three times in a minute: not a fourth time")
    func notAFourthTime() async throws {
        let fake = try FakeHelperProgram(exitCodes: [3, 3, 3, 3, 3, 3])
        let owner = issuer([])
        let helper = supervisor(fake)

        _ = await helper.start(apiBaseURL: apiURL, issuer: owner)
        #expect(await eventually { await helper.state() == .stoppedTrying })
        // Give a fifth start the time it would need, then count.
        try await Task.sleep(for: .milliseconds(300))
        #expect(fake.runs == 4)
        #expect(owner.calls.count == 4)
        #expect(await helper.state() == .stoppedTrying)
        await fake.expectNothingLeft()
    }

    @Test("Try again after it stopped trying starts counting again")
    func tryAgain() async throws {
        let fake = try FakeHelperProgram(exitCodes: [3, 3, 3, 3])
        let owner = issuer([])
        let helper = supervisor(fake)

        _ = await helper.start(apiBaseURL: apiURL, issuer: owner)
        #expect(await eventually { await helper.state() == .stoppedTrying })
        #expect(await helper.tryAgain() == .running)
        #expect(await eventually { fake.runs == 5 })
        #expect(await helper.state() == .running)
        await helper.stop()
        await fake.expectNothingLeft()
    }

    @Test("failures more than a minute apart do not add up")
    func windowIsOneMinute() async throws {
        let fake = try FakeHelperProgram(exitCodes: [3, 3, 3, 3, 3])
        let owner = issuer([])
        // Each look at the clock is 61 seconds after the one before.
        let clock = Locked(Date(timeIntervalSince1970: 1_800_000_000))
        let helper = supervisor(fake, now: { clock.update { $0 += 61; return $0 } })

        _ = await helper.start(apiBaseURL: apiURL, issuer: owner)
        #expect(await eventually { fake.runs == 6 })
        #expect(await eventually { await helper.state() == .running })
        await helper.stop()
        await fake.expectNothingLeft()
    }

    @Test("stop asks the helper to stop, waits for it, and does not start it again")
    func stopAsksAndWaits() async throws {
        let fake = try FakeHelperProgram(exitCodes: [])
        let owner = issuer(["lvh_made-up-1"])
        let helper = supervisor(fake)

        _ = await helper.start(apiBaseURL: apiURL, issuer: owner)
        #expect(await eventually { !fake.environment(ofRun: 1).isEmpty })
        await helper.stop()
        #expect(await helper.state() == .stopped)
        let log = textOfEveryFile(under: fake.support)["logs/helper.log"] ?? ""
        #expect(log.contains("fake helper run 1 asked to stop"))
        try await Task.sleep(for: .milliseconds(200))
        #expect(fake.runs == 1)
        #expect(owner.calls.count == 1)
        await fake.expectNothingLeft()
    }

    @Test("a second start while it runs starts nothing more")
    func secondStartIsNoOp() async throws {
        let fake = try FakeHelperProgram(exitCodes: [])
        let owner = issuer(["lvh_made-up-1"])
        let helper = supervisor(fake)

        _ = await helper.start(apiBaseURL: apiURL, issuer: owner)
        #expect(await helper.start(apiBaseURL: apiURL, issuer: owner) == .running)
        #expect(owner.calls.count == 1)
        await helper.stop()
        await fake.expectNothingLeft()
    }

    @Test("a start that was waiting for its token when the owner stopped and started again starts no second helper")
    func staleLaunchStartsNothing() async throws {
        let fake = try FakeHelperProgram(exitCodes: [])
        let slowFirst = SlowFirstIssuer()
        let helper = supervisor(fake)

        let first = Task { await helper.start(apiBaseURL: apiURL, issuer: slowFirst) }
        #expect(await eventually { slowFirst.calls.value == 1 })
        await helper.stop()
        #expect(await helper.start(apiBaseURL: apiURL, issuer: slowFirst) == .running)
        _ = await first.value
        #expect(await eventually { fake.runs == 1 && !fake.environment(ofRun: 1).isEmpty })
        try await Task.sleep(for: .milliseconds(500))
        #expect(fake.runs == 1)
        #expect(fake.environment(ofRun: 1)["LEVERAGE_HELPER_TOKEN"] == "lvh_made-up-2")
        await helper.stop()
        await fake.expectNothingLeft()
    }

    @Test("a token that cannot be issued counts as a failed start")
    func issueFails() async throws {
        let fake = try FakeHelperProgram(exitCodes: [])
        let owner = FakeOwnerAPI()  // nothing scripted: every call throws
        let helper = supervisor(fake)

        _ = await helper.start(apiBaseURL: apiURL, issuer: owner)
        #expect(await eventually { await helper.state() == .stoppedTrying })
        #expect(fake.runs == 0)
        #expect(owner.calls.count == 4)
        await fake.expectNothingLeft()
    }

    @Test("the helper's log is replaced when it passes its limit")
    func logIsReplaced() async throws {
        let fake = try FakeHelperProgram(exitCodes: [])
        let logs = fake.support.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try Data(repeating: UInt8(ascii: "x"), count: 2_000).write(to: logs.appendingPathComponent("helper.log"))
        var configuration = HelperSupervisor.Configuration(
            helperProgram: fake.program, supportFolder: fake.support, environment: parentEnvironment)
        configuration.logLimitBytes = 1_000
        let helper = HelperSupervisor(configuration: configuration, log: Log(component: "test", write: { _ in }))

        _ = await helper.start(apiBaseURL: apiURL, issuer: issuer(["lvh_made-up-1"]))
        #expect(await eventually { fake.runs == 1 })
        await helper.stop()
        let files = textOfEveryFile(under: fake.support)
        // The new log holds this run's lines and none of the old one's (the
        // shell may first say that the fake's sleep was ended).
        let current = files["logs/helper.log"] ?? ""
        #expect(current.contains("fake helper run 1") && !current.contains("xxxxxxxxxx"), "\(current)")
        #expect(files["logs/helper.log.1"]?.count == 2_000)
        await fake.expectNothingLeft()
    }

    // MARK: Nothing outlives its stop, and no stop loses a helper

    @Test("a second stop while the first still waits for the helper also waits for it")
    func secondStopWaitsToo() async throws {
        let fake = try FakeHelperProgram(exitCodes: [])
        try fake.holdOnStop(run: 1)
        let helper = supervisor(fake)

        #expect(await helper.start(apiBaseURL: apiURL, issuer: issuer([])) == .running)
        #expect(await eventually { fake.isRunning(run: 1) })
        let firstStop = Task { await helper.stop() }
        #expect(await eventually { fake.log.contains("fake helper run 1 asked to stop") })

        // As when the owner quits while a Sign out still stops the helper:
        // the quit must not go on while the helper still runs.
        let secondStop = Task {
            await helper.stop()
            return fake.isRunning(run: 1)
        }
        try await Task.sleep(for: .milliseconds(300))
        fake.letGo(run: 1)
        #expect(await secondStop.value == false)
        await firstStop.value
        #expect(await helper.state() == .stopped)
        await fake.expectNothingLeft()
    }

    @Test("a start while a stop still waits for the helper starts a new one once the old one has ended")
    func startDuringStopStartsAfterIt() async throws {
        let fake = try FakeHelperProgram(exitCodes: [])
        try fake.holdOnStop(run: 1)
        let owner = issuer([])
        let helper = supervisor(fake)

        #expect(await helper.start(apiBaseURL: apiURL, issuer: owner) == .running)
        #expect(await eventually { fake.isRunning(run: 1) })
        let stopping = Task { await helper.stop() }
        #expect(await eventually { fake.log.contains("fake helper run 1 asked to stop") })

        // As when the owner signs out and at once signs in again.
        let starting = Task { await helper.start(apiBaseURL: apiURL, issuer: owner) }
        try await Task.sleep(for: .milliseconds(300))
        #expect(fake.runs == 1, "a second helper started while the first one still ran")
        fake.letGo(run: 1)
        #expect(await starting.value == .running)
        await stopping.value

        // The stop that ended before the start does not hide the new helper.
        #expect(await helper.state() == .running)
        #expect(await eventually(within: .seconds(5)) { fake.runs == 2 && fake.isRunning(run: 2) })
        #expect(await helper.start(apiBaseURL: apiURL, issuer: owner) == .running)
        try await Task.sleep(for: .milliseconds(200))
        #expect(fake.runs == 2)
        await helper.stop()
        #expect(!fake.isRunning(run: 2))
        await fake.expectNothingLeft()
    }

    @Test("a fake helper whose parent is gone ends by itself, as the real one does, so a crashed test run leaves none")
    func fakeEndsWithItsParent() async throws {
        let fake = try FakeHelperProgram(exitCodes: [])
        // A shell starts the fake in the background and exits at once, as
        // the test process did when it crashed while a fake ran.
        let parent = Process()
        parent.executableURL = URL(fileURLWithPath: "/bin/sh")
        parent.arguments = ["-c", "\"$0\" </dev/null >/dev/null 2>&1 &", fake.program.path]
        parent.environment = ["PATH": "/usr/bin:/bin"]
        try parent.run()
        parent.waitUntilExit()

        #expect(await eventually { fake.processID(ofRun: 1) != nil })
        #expect(await eventually(within: .seconds(10)) { !fake.isRunning(run: 1) })
        await fake.expectNothingLeft()
    }

    @Test("the folders a crashed test run left are removed by the next run, and no other run's")
    func foldersOfCrashedRunsAreRemoved() async throws {
        let parent = try TemporaryFolder(prefix: "leverage-helper-supervisor-sweep")
        func fakeFolder(_ name: String, testProcess: pid_t?) throws -> URL {
            let folder = try parent.folder(name)
            try FileManager.default.createDirectory(
                at: folder.appendingPathComponent("state"), withIntermediateDirectories: true)
            if let testProcess {
                try Data("\(testProcess)\n".utf8).write(to: folder.appendingPathComponent("state/test-process"))
            }
            return folder
        }
        // A process that has ended, as the crashed test run has.
        let ended = Process()
        ended.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try ended.run()
        ended.waitUntilExit()

        let crashed = try fakeFolder("leverage-helper-supervisor-crashed", testProcess: ended.processIdentifier)
        let otherRun = try fakeFolder("leverage-helper-supervisor-other", testProcess: getppid())
        let thisRun = try fakeFolder("leverage-helper-supervisor-this", testProcess: getpid())
        let notRecordedYet = try fakeFolder("leverage-helper-supervisor-new", testProcess: nil)
        let notAFake = try fakeFolder("leverage-something-else", testProcess: ended.processIdentifier)
        // A fake still runs from this folder though its test run has ended.
        let stillRuns = try fakeFolder("leverage-helper-supervisor-runs", testProcess: ended.processIdentifier)
        // The shell waits in `read`, a builtin, so it has no child to leave
        // behind when it is ended.
        let input = Pipe()
        let running = Process()
        running.executableURL = URL(fileURLWithPath: "/bin/sh")
        running.arguments = ["-c", "read line", stillRuns.appendingPathComponent("bin/LeverageHelper").path]
        running.standardInput = input
        try running.run()
        defer {
            running.terminate()
            running.waitUntilExit()
        }

        FakeHelperProgram.removeFoldersOfEndedTestRuns(in: parent.url)

        let manager = FileManager.default
        #expect(!manager.fileExists(atPath: crashed.path))
        for kept in [otherRun, thisRun, notRecordedYet, notAFake, stillRuns] {
            #expect(manager.fileExists(atPath: kept.path), "\(kept.lastPathComponent) was removed")
        }
    }
}

/// Answers its first call only after half a second, each with a new token.
private final class SlowFirstIssuer: HelperTokenIssuing, @unchecked Sendable {
    let calls = Locked(0)

    func issueHelperToken(name: String, idempotencyKey: String) async throws -> String? {
        let n = calls.update { value -> Int in
            value += 1
            return value
        }
        if n == 1 { try await Task.sleep(for: .milliseconds(500)) }
        return "lvh_made-up-\(n)"
    }
}
