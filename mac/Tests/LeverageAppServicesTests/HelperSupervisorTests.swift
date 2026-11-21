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
private let credentialTokenMarker = "LVRG-" + "TOKEN-"

@Suite("HelperSupervisor")
struct HelperSupervisorTests {
    private func supervisor(
        _ fake: FakeHelperProgram,
        environment: [String: String] = parentEnvironment,
        now: @escaping @Sendable () -> Date = { Date() },
        log: Log = Log(component: "test", write: { _ in })
    ) -> HelperSupervisor {
        var configuration = HelperSupervisor.Configuration(
            helperProgram: fake.program, supportFolder: fake.support, environment: environment)
        configuration.restartDelay = .zero
        configuration.stopGracePeriod = Patience.scaled(.seconds(5))
        return HelperSupervisor(configuration: configuration, now: now, log: log)
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

    @Test("a token goes through the shell launcher as one JSON line, outside arguments, environment and logs")
    func sendsTokenOnStandardInputOnly() async throws {
        let fake = try FakeHelperProgram(exitCodes: [], input: .recorded)
        let entries = Locked<[String]>([])
        let helper = supervisor(fake, log: Log(component: "test", write: { entry in
            entries.update { $0.append(entry) }
        }))
        let id = UUID()
        let token = "\(credentialTokenMarker)facedeadbeef\r\nmade-up tail"

        #expect(await helper.start(apiBaseURL: apiURL, issuer: issuer([])) == .running)
        let helperReady = await eventually { fake.log.contains("fake helper run 1") }
        #expect(helperReady)
        do {
            try await helper.send(.token(credentialID: id, token: token))
            #expect(await eventually { fake.inputLines(ofRun: 1).count == 1 })
        } catch {
            Issue.record("token send failed while the helper was running")
        }
        await helper.stop()

        let lines = fake.inputLines(ofRun: 1)
        #expect(lines.count == 1)
        let sent = lines.first.flatMap { try? LocalHelperMessage.decodeLine($0) }
        if case .token(let receivedID, let receivedToken) = sent {
            #expect(receivedID == id)
            let tokenUnchanged = receivedToken == token
            #expect(tokenUnchanged)
        } else {
            Issue.record("the helper did not receive a token message")
        }
        let arguments = fake.arguments(ofRun: 1)
        let environment = fake.environment(ofRun: 1)
        let helperLog = fake.log
        let recordedLaunch = !arguments.isEmpty && environment["HOME"] != nil
        let loggedStart = helperLog.contains("fake helper run 1") && entries.value.contains {
            $0.contains("the helper started")
        }
        #expect(recordedLaunch)
        #expect(loggedStart)
        let launch = [arguments] + Array(environment.values)
        let leakedID = launch.contains { $0.localizedCaseInsensitiveContains(id.uuidString) }
        #expect(!leakedID)
        let launchedAndLogged = launch + [helperLog] + entries.value
        let leakedToken = launchedAndLogged.contains { $0.contains(credentialTokenMarker) }
        #expect(!leakedToken)
        await fake.expectNothingLeft()
    }

    @Test("two sends arrive as separate lines in send order")
    func keepsSendOrder() async throws {
        let fake = try FakeHelperProgram(exitCodes: [], input: .recorded)
        let helper = supervisor(fake)
        let first = UUID()
        let second = UUID()

        #expect(await helper.start(apiBaseURL: apiURL, issuer: issuer([])) == .running)
        do {
            try await helper.send(.forget(credentialID: first))
            try await helper.send(.forget(credentialID: second))
            #expect(await eventually { fake.inputLines(ofRun: 1).count == 2 })
        } catch {
            Issue.record("send failed while the helper was running: \(error)")
        }
        await helper.stop()
        let lines = fake.inputLines(ofRun: 1)
        #expect(lines.count == 2)
        let ids = lines.compactMap { line -> UUID? in
            guard case .forget(let id) = try? LocalHelperMessage.decodeLine(line) else { return nil }
            return id
        }
        #expect(ids == [first, second])
        await fake.expectNothingLeft()
    }

    @Test("confirmed removal survives relaunch and a pipe write until the helper acknowledges it")
    func replaysConfirmedRemoval() async throws {
        let fake = try FakeHelperProgram(exitCodes: [3], input: .recorded)
        let id = UUID()
        let first = supervisor(fake)
        await #expect(throws: HelperSendError.notRunning) { try await first.send(.forget(credentialID: id)) }
        let receipt = fake.support.appendingPathComponent("pending-removals/\(id.contractString)")
        #expect(FileManager.default.fileExists(atPath: receipt.path))
        let next = supervisor(fake)
        _ = await next.start(apiBaseURL: apiURL, issuer: issuer([]))
        #expect(await eventually {
            fake.inputLines(ofRun: 2).contains { line in
                guard case .forget(let received) = try? LocalHelperMessage.decodeLine(line) else { return false }
                return received == id
            }
        })
        #expect(FileManager.default.fileExists(atPath: receipt.path))
        await next.stop()
        await fake.expectNothingLeft()
    }

    @Test("sending without a running helper throws before start and after stop")
    func refusesSendWithoutHelper() async throws {
        let fake = try FakeHelperProgram(exitCodes: [])
        let helper = supervisor(fake)
        let message = LocalHelperMessage.forget(credentialID: UUID())

        await #expect(throws: HelperSendError.notRunning) { try await helper.send(message) }
        #expect(await helper.start(apiBaseURL: apiURL, issuer: issuer([])) == .running)
        await helper.stop()
        await #expect(throws: HelperSendError.notRunning) { try await helper.send(message) }
        await fake.expectNothingLeft()
    }

    @Test("sending to closed standard input throws and leaves the app and helper running")
    func refusesSendAfterChildClosesInput() async throws {
        let fake = try FakeHelperProgram(exitCodes: [], input: .closed)
        let helper = supervisor(fake)

        #expect(await helper.start(apiBaseURL: apiURL, issuer: issuer([])) == .running)
        #expect(await eventually { fake.log.contains("fake helper run 1") })
        await #expect(throws: HelperSendError.notRunning) {
            try await helper.send(.forget(credentialID: UUID()))
        }
        #expect(fake.isRunning(run: 1))
        await helper.stop()
        await fake.expectNothingLeft()
    }

    @Test("a cancelled caller can send cleanup without stopping the shared helper")
    func cancelledSendLeavesHelperRunning() async throws {
        let fake = try FakeHelperProgram(exitCodes: [], input: .recorded)
        let helper = supervisor(fake)
        let first = UUID()
        let second = UUID()

        #expect(await helper.start(apiBaseURL: apiURL, issuer: issuer([])) == .running)
        #expect(await eventually { fake.log.contains("fake helper run 1") })
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await helper.send(.forget(credentialID: first))
        }
        do {
            try await cancelled.value
            try await helper.send(.forget(credentialID: second))
            #expect(await eventually { fake.inputLines(ofRun: 1).count >= 2 || fake.runs > 1 })
        } catch {
            Issue.record("send failed in the cancellation test: \(error)")
        }
        #expect(fake.isRunning(run: 1))
        await helper.stop()
        #expect(fake.runs == 1)
        let lines = fake.inputLines(ofRun: 1)
        #expect(lines.count == 2)
        let ids = lines.compactMap { line -> UUID? in
            guard case .forget(let id) = try? LocalHelperMessage.decodeLine(line) else { return nil }
            return id
        }
        #expect(ids == [first, second])
        await fake.expectNothingLeft()
    }

    @Test("the token store setting reaches the helper and the provider API override stays out")
    func passesOnlyAllowedTokenConfiguration() async throws {
        let fake = try FakeHelperProgram(exitCodes: [])
        var environment = parentEnvironment
        environment["LEVERAGE_TOKEN_STORE"] = "memory"
        environment["LEVERAGE_PROVIDER_API_BASE"] = "http://127.0.0.1:47131"
        let helper = supervisor(fake, environment: environment)

        #expect(await helper.start(apiBaseURL: apiURL, issuer: issuer([])) == .running)
        #expect(await eventually { fake.log.contains("fake helper run 1") })
        let launched = fake.environment(ofRun: 1)
        #expect(launched["HOME"] != nil)
        #expect(launched["LEVERAGE_TOKEN_STORE"] == "memory")
        #expect(launched["LEVERAGE_PROVIDER_API_BASE"] == nil)
        await helper.stop()
        await fake.expectNothingLeft()
    }

    @Test("a send after exit code 3 goes to the replacement helper")
    func sendsToReplacement() async throws {
        let fake = try FakeHelperProgram(exitCodes: [3], input: .recorded)
        let helper = supervisor(fake)
        let id = UUID()

        _ = await helper.start(apiBaseURL: apiURL, issuer: issuer([]))
        #expect(await eventually { fake.runs == 2 && fake.log.contains("fake helper run 2") })
        #expect(await helper.state() == .running)
        do {
            try await helper.send(.forget(credentialID: id))
            #expect(await eventually { fake.inputLines(ofRun: 2).count == 1 })
        } catch {
            Issue.record("send failed after the helper restarted: \(error)")
        }
        await helper.stop()
        #expect(fake.inputLines(ofRun: 1).isEmpty)
        let lines = fake.inputLines(ofRun: 2)
        #expect(lines.count == 1)
        if case .forget(let received) = lines.first.flatMap({ try? LocalHelperMessage.decodeLine($0) }) {
            #expect(received == id)
        } else {
            Issue.record("the replacement helper did not receive a forget message")
        }
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

    @Test("a stop while a start still waits for an earlier stop's helper starts nothing, and leaves the state stopped")
    func stopDuringWaitingStartStartsNothing() async throws {
        let fake = try FakeHelperProgram(exitCodes: [])
        try fake.holdOnStop(run: 1)
        let owner = issuer([])
        let helper = supervisor(fake)

        #expect(await helper.start(apiBaseURL: apiURL, issuer: owner) == .running)
        #expect(await eventually { fake.isRunning(run: 1) })
        let firstStop = Task { await helper.stop() }
        #expect(await eventually { fake.log.contains("fake helper run 1 asked to stop") })

        // As when the owner signs out, signs in again at once, and quits
        // while the first helper still ends.
        let starting = Task { await helper.start(apiBaseURL: apiURL, issuer: owner) }
        #expect(await eventually { await helper.state() == .starting })
        let secondStop = Task { await helper.stop() }
        #expect(await eventually { await helper.state() == .stopped })
        fake.letGo(run: 1)

        #expect(await starting.value == .stopped)
        await firstStop.value
        await secondStop.value
        #expect(await helper.state() == .stopped)
        try await Task.sleep(for: .milliseconds(300))
        #expect(fake.runs == 1)
        #expect(owner.calls.count == 1)
        #expect(await helper.state() == .stopped)
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
