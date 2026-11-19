import Foundation
import LeverageKit
import LeverageTestSupport
import Testing

@testable import LeverageAppServices

/// A fake helper program in a temporary folder. Run n records its
/// environment in `state/env-<n>` and its arguments in `state/args-<n>`,
/// writes one line to standard error, and then exits with line n of
/// `state/codes`, or, past the end of that file, runs until it is asked to
/// stop.
final class FakeHelperProgram: @unchecked Sendable {
    let folder: TemporaryFolder
    var program: URL { folder.url.appendingPathComponent("bin/LeverageHelper") }
    var state: URL { folder.url.appendingPathComponent("state") }
    var support: URL { folder.url.appendingPathComponent("support") }

    init(exitCodes: [Int32]) throws {
        folder = try TemporaryFolder(prefix: "leverage-helper-supervisor")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        try Data(exitCodes.map { "\($0)\n" }.joined().utf8).write(to: state.appendingPathComponent("codes"))
        let dir = state.path
        try writeScript(program, """
            #!/bin/sh
            dir='\(dir)'
            n=$(( $(cat "$dir/count" 2>/dev/null || echo 0) + 1 ))
            echo "$n" > "$dir/count"
            env | grep -v -E '^(PWD|OLDPWD|SHLVL|_)=' | sort > "$dir/env-$n"
            printf '%s\\n' "$0" "$@" > "$dir/args-$n"
            echo "fake helper run $n" >&2
            code=$(sed -n "${n}p" "$dir/codes")
            if [ -n "$code" ]; then exit "$code"; fi
            trap 'echo "fake helper run $n asked to stop" >&2; exit 0' TERM
            while :; do sleep 0.05; done
            """)
    }

    var runs: Int {
        Int((try? String(contentsOf: state.appendingPathComponent("count"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
    }

    func environment(ofRun n: Int) -> [String: String] {
        let text = (try? String(contentsOf: state.appendingPathComponent("env-\(n)"), encoding: .utf8)) ?? ""
        var found: [String: String] = [:]
        for line in text.split(separator: "\n") {
            if let equals = line.firstIndex(of: "=") {
                found[String(line[..<equals])] = String(line[line.index(after: equals)...])
            }
        }
        return found
    }

    func arguments(ofRun n: Int) -> String {
        (try? String(contentsOf: state.appendingPathComponent("args-\(n)"), encoding: .utf8)) ?? ""
    }
}

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
        configuration.stopGracePeriod = .seconds(5)
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
        #expect(files["logs/helper.log"]?.hasPrefix("fake helper run 1") == true)
        #expect(files["logs/helper.log.1"]?.count == 2_000)
    }
}
