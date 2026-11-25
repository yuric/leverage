import Foundation
import LeverageKit
import LeverageTestSupport
import Testing

@testable import LeverageRunner

// Each driver against its stand-in tool (PV-7): arguments exactly as PV-2,
// the account variable set, no Leverage token in the tool's environment, a
// signed-out stand-in is a failure.
@Suite("Drivers against the stand-ins", .timeLimit(.minutes(Patience.minutes(2))))
struct DriverTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let tool: String
        let provider: String
        let accountVariable: String?
        let tokens: Int
        var testDescription: String { tool }
    }

    static let cases = [
        Case(tool: "claude", provider: "claude", accountVariable: "CLAUDE_CONFIG_DIR", tokens: 150),
        Case(tool: "codex", provider: "codex", accountVariable: "CODEX_HOME", tokens: 240),
        Case(tool: "agy", provider: "gemini", accountVariable: nil, tokens: 110),
        Case(tool: "grok", provider: "grok", accountVariable: nil, tokens: 0),
    ]

    static let fakeSeatToken = "lvs_made_up_seat_token_never_for_a_tool"
    static let fakeHelperToken = "lvh_made_up_helper_token_never_for_a_tool"

    final class Setup: Sendable {
        let folder: TemporaryFolder
        let tools: StandInTools
        let account: URL
        let work: URL

        init() throws {
            folder = try TemporaryFolder(prefix: "leverage-drivers")
            tools = try StandIns.copy(into: folder.url)
            account = try folder.folder("account")
            work = try folder.folder("work")
        }

        func environment(_ test: Case, model: String? = "model-x", effort: String? = "high", timeout: Int = 120)
            -> [String: String] {
            var values = [
                "LEVERAGE_SEAT_TOKEN": DriverTests.fakeSeatToken,
                "LEVERAGE_HELPER_TOKEN": DriverTests.fakeHelperToken,
                "LEVERAGE_SEAT_ROLE": "builder",
                "LEVERAGE_PROVIDER": test.provider,
                "LEVERAGE_TOOL_PATH": tools.tool(test.tool).path,
                "LEVERAGE_TOOL_DIR": tools.bin.path,
                "LEVERAGE_SUPPORT_DIR": folder.path("support").path,
                "LEVERAGE_TOOL_TIMEOUT_SECONDS": String(timeout),
                "HOME": folder.url.path,
                "TMPDIR": folder.url.path,
                "LANG": "en_US.UTF-8",
                "USER": "standin",
                "FOO": "not for the tool",
            ]
            if test.accountVariable != nil { values["LEVERAGE_SETTINGS_DIR"] = account.path }
            if let model { values["LEVERAGE_MODEL"] = model }
            if let effort { values["LEVERAGE_EFFORT"] = effort }
            return values
        }

        func driver(_ test: Case, model: String? = "model-x", effort: String? = "high", timeout: Int = 120) throws
            -> ProcessToolDriver {
            try ProcessToolDriver(
                tool: ToolConfiguration(environment: environment(test, model: model, effort: effort, timeout: timeout)))
        }

        func signIn(_ test: Case) throws {
            try tools.signIn(test.tool, accountFolder: test.accountVariable == nil ? nil : account)
        }

        func lastCall() throws -> StandInCall {
            try #require(try tools.calls().last)
        }
    }

    static let buildPrompt = "Do criterion 1 now. End with LEVERAGE-EVIDENCE: <where> or LEVERAGE-CANNOT: <why>."
    static let reviewPrompt = "Check criterion 1 and criterion 2. Answer LEVERAGE-CRITERION <n>: PASS or FAIL."

    /// PV-2, as the arguments after the program; `<file>` stands for
    /// Codex's output file.
    static func expectedArguments(_ test: Case, _ purpose: ToolPurpose, prompt: String, folder: String) -> [String] {
        switch (test.tool, purpose) {
        case ("claude", .check):
            return ["-p", prompt, "--output-format", "json", "--no-session-persistence", "--permission-mode",
                    "dontAsk", "--strict-mcp-config", "--setting-sources", "user", "--tools", ""]
        case ("claude", .review):
            return ["-p", prompt, "--output-format", "json", "--no-session-persistence", "--permission-mode",
                    "dontAsk", "--strict-mcp-config", "--setting-sources", "user", "--model", "model-x",
                    "--effort", "high"]
        case ("claude", .build):
            return ["-p", prompt, "--output-format", "json", "--no-session-persistence", "--permission-mode",
                    "acceptEdits", "--strict-mcp-config", "--setting-sources", "user", "--model", "model-x",
                    "--effort", "high"]
        case ("codex", .check):
            return ["exec", prompt, "--json", "--sandbox", "read-only", "--skip-git-repo-check", "--ephemeral",
                    "-C", folder, "-o", "<file>"]
        case ("codex", .review):
            return ["exec", prompt, "--json", "--sandbox", "read-only", "--skip-git-repo-check", "--ephemeral",
                    "-C", folder, "-o", "<file>", "-m", "model-x"]
        case ("codex", .build):
            return ["exec", prompt, "--json", "--sandbox", "workspace-write", "--skip-git-repo-check",
                    "--ephemeral", "-C", folder, "-o", "<file>", "-m", "model-x"]
        case ("agy", .check):
            return ["-p", prompt, "--output-format", "json", "--print-timeout", "120s"]
        case ("agy", .review):
            return ["-p", prompt, "--output-format", "json", "--print-timeout", "120s", "--mode", "plan",
                    "--model", "model-x", "--effort", "high"]
        case ("agy", .build):
            return ["-p", prompt, "--output-format", "json", "--print-timeout", "120s", "--mode", "accept-edits",
                    "--model", "model-x", "--effort", "high"]
        case ("grok", .check):
            return ["-p", prompt, "--cwd", folder]
        case ("grok", .review):
            return ["-p", prompt, "--cwd", folder, "--permission-mode", "plan", "-m", "model-x"]
        case ("grok", .build):
            return ["-p", prompt, "--cwd", folder, "--permission-mode", "acceptEdits", "-m", "model-x"]
        default:
            return []
        }
    }

    /// Codex's output file is a fresh path each run: compared as `<file>`.
    static func normalised(_ argv: [String]) -> [String] {
        guard let index = argv.firstIndex(of: "-o"), index + 1 < argv.count else { return argv }
        var copy = argv
        copy[index + 1] = "<file>"
        return copy
    }

    @Test("the arguments of a build, a review and the answering check are exactly PV-2's",
          arguments: cases, [ToolPurpose.build, .review, .check])
    func arguments(test: Case, purpose: ToolPurpose) async throws {
        let setup = try Setup()
        try setup.signIn(test)
        let prompt = purpose == .review ? Self.reviewPrompt : (purpose == .build ? Self.buildPrompt : Prompts.ready)
        _ = try await setup.driver(test).run(prompt: prompt, in: setup.work, purpose: purpose)

        let call = try setup.lastCall()
        #expect(call.tool == test.tool)
        #expect(Self.normalised(call.argv) == Self.expectedArguments(test, purpose, prompt: prompt,
                                                                     folder: setup.work.path))
        #expect(call.cwd == setup.work.path)
        if let index = call.argv.firstIndex(of: "-o") {
            let file = call.argv[index + 1]
            #expect(file.hasPrefix("/"))
            #expect(!file.hasPrefix(setup.work.path))
            #expect(!FileManager.default.fileExists(atPath: file), "the output file is removed after the run")
        }
    }

    @Test("with no model and no effort, neither is passed", arguments: cases)
    func noModel(test: Case) async throws {
        let setup = try Setup()
        try setup.signIn(test)
        _ = try await setup.driver(test, model: nil, effort: nil)
            .run(prompt: Self.buildPrompt, in: setup.work, purpose: .build)
        let argv = try setup.lastCall().argv
        for flag in ["--model", "-m", "--effort"] {
            #expect(!argv.contains(flag))
        }
    }

    @Test("a seat's effort reaches the tool exactly for the providers the catalog says take one", arguments: cases)
    func effortMatchesCatalog(test: Case) async throws {
        let setup = try Setup()
        try setup.signIn(test)
        _ = try await setup.driver(test, effort: "made-up-effort")
            .run(prompt: Self.buildPrompt, in: setup.work, purpose: .build)
        let provider = try #require(Provider(rawValue: test.provider))
        #expect(try setup.lastCall().argv.contains("made-up-effort") == (ModelCatalog.entry(for: provider)?.nativeEffort.value == true))
    }

    @Test("the tool's environment: the allow-list, the account variable, no Leverage token", arguments: cases)
    func environment(test: Case) async throws {
        let setup = try Setup()
        try setup.signIn(test)
        _ = try await setup.driver(test).run(prompt: Self.buildPrompt, in: setup.work, purpose: .build)

        let env = try setup.lastCall().env
        #expect(env.keys.allSatisfy { !$0.hasPrefix("LEVERAGE_") })
        #expect(!env.values.contains { $0.contains(Self.fakeSeatToken) || $0.contains(Self.fakeHelperToken) })
        #expect(env["FOO"] == nil)
        #expect(env["PATH"] == "\(setup.tools.bin.path):/usr/bin:/bin")
        #expect(env["HOME"] == setup.folder.url.path)
        #expect(env["LANG"] == "en_US.UTF-8")
        if let variable = test.accountVariable {
            #expect(env[variable] == setup.account.path)
        }
        for other in ["CLAUDE_CONFIG_DIR", "CODEX_HOME"] where other != test.accountVariable {
            #expect(env[other] == nil)
        }
        #expect((env["USER"] != nil) == (test.tool == "claude"), "only Claude's allow-list has USER")
    }

    @Test("a build's answer is read from the tool's output, with its tokens", arguments: cases)
    func buildAnswer(test: Case) async throws {
        let setup = try Setup()
        try setup.signIn(test)
        let answer = try await setup.driver(test).run(prompt: Self.buildPrompt, in: setup.work, purpose: .build)

        #expect(AnswerParser.builder(answer.text) == .evidence("criterion-1.txt in \(setup.work.path)"))
        #expect(answer.tokens == test.tokens)
        #expect(FileManager.default.fileExists(atPath: setup.work.appendingPathComponent("criterion-1.txt").path))
    }

    @Test("a review's answer is read from the tool's output", arguments: cases)
    func reviewAnswer(test: Case) async throws {
        let setup = try Setup()
        try setup.signIn(test)
        try setup.tools.write(scenario: StandInScenario(reviews: [.init(fail: [2], notes: "Two is off.")]))
        let answer = try await setup.driver(test).run(prompt: Self.reviewPrompt, in: setup.work, purpose: .review)

        #expect(AnswerParser.reviewer(answer.text, expecting: [1, 2]) == ReviewAnswer(failed: [2], notes: "Two is off."))
    }

    @Test("a signed-out stand-in is a failure", arguments: cases)
    func signedOut(test: Case) async throws {
        let setup = try Setup()
        await #expect(throws: ToolFailure.self) {
            _ = try await setup.driver(test).run(prompt: Self.buildPrompt, in: setup.work, purpose: .build)
        }
    }

    @Test("a run past its time limit is a timeout")
    func timeLimit() async throws {
        let setup = try Setup()
        let test = Self.cases[0]
        try setup.signIn(test)
        try setup.tools.write(scenario: StandInScenario(gateFile: "never-opened"))
        await #expect(throws: ToolFailure.timedOut) {
            _ = try await setup.driver(test, timeout: 1).run(prompt: Self.reviewPrompt, in: setup.work, purpose: .review)
        }
    }

    @Test("cancelling a run ends the tool at once")
    func cancelled() async throws {
        let setup = try Setup()
        let test = Self.cases[1]
        try setup.signIn(test)
        try setup.tools.write(scenario: StandInScenario(gateFile: "never-opened"))
        let driver = try setup.driver(test)
        let work = setup.work
        let run = Task { try await driver.run(prompt: Self.reviewPrompt, in: work, purpose: .review) }
        #expect(await eventually { ((try? setup.tools.calls()) ?? []).count == 1 })
        let started = ContinuousClock.now
        run.cancel()
        let result = await run.result
        #expect(ContinuousClock.now - started < .seconds(10))
        #expect(throws: CancellationError.self) { try result.get() }
    }

    // MARK: A job's check run (milestone 4, plan section 2.2, RD-33, RD-34)

    /// What only a build or a review passes: an editing or planning mode.
    static let forbidden = ["--mode", "plan", "acceptEdits", "accept-edits", "workspace-write"]

    /// The merged check arguments, with the job's time limit where the tool
    /// takes one (`agy --print-timeout`).
    static func checkArguments(_ test: Case, prompt: String, folder: String, seconds: Int) -> [String] {
        expectedArguments(test, .check, prompt: prompt, folder: folder)
            .map { $0 == "120s" ? "\(seconds)s" : $0 }
    }

    @Test("a job's check run has the merged check arguments and the job's time limit; never a mode that edits or plans, Gemini's --mode plan included (§0.1 facts 15, 27)", arguments: cases)
    func jobCheckArguments(test: Case) async throws {
        let setup = try Setup()
        try setup.signIn(test)
        let request = ToolRunRequest(
            prompt: Prompts.ready, folder: setup.work, purpose: .check, timeLimitSeconds: 45, seatModel: false)
        _ = try await setup.driver(test).execute(request)
        let argv = Self.normalised(try setup.lastCall().argv)
        #expect(argv == Self.checkArguments(test, prompt: Prompts.ready, folder: setup.work.path, seconds: 45))
        #expect(!argv.contains { Self.forbidden.contains($0) })
    }

    @Test("a job's check run passes the seat's model and effort when they are set, and nothing else changes",
          arguments: cases)
    func jobCheckModel(test: Case) async throws {
        let setup = try Setup()
        try setup.signIn(test)
        let request = ToolRunRequest(
            prompt: Prompts.ready, folder: setup.work, purpose: .check, timeLimitSeconds: 45, seatModel: true)
        _ = try await setup.driver(test, model: "model-x", effort: "high").execute(request)
        let argv = Self.normalised(try setup.lastCall().argv)
        let base = Self.checkArguments(test, prompt: Prompts.ready, folder: setup.work.path, seconds: 45)
        #expect(Array(argv.prefix(base.count)) == base)
        let provider = try #require(Provider(rawValue: test.provider))
        let modelFlag = ["claude": "--model", "agy": "--model"][test.tool] ?? "-m"
        var extra = [modelFlag, "model-x"]
        if (ModelCatalog.entry(for: provider)?.nativeEffort.value == true) { extra += ["--effort", "high"] }
        #expect(Array(argv.dropFirst(base.count)) == extra)
        #expect(!argv.contains { Self.forbidden.contains($0) })
        // The probe's answering check never takes the seat's model.
        _ = try await setup.driver(test, model: "model-x", effort: "high")
            .run(prompt: Prompts.ready, in: setup.work, purpose: .check)
        #expect(Self.normalised(try setup.lastCall().argv)
            == Self.expectedArguments(test, .check, prompt: Prompts.ready, folder: setup.work.path))
    }

    @Test("a job's time limit ends the tool, and never lengthens the configuration's")
    func jobTimeLimit() async throws {
        let setup = try Setup()
        let test = Self.cases[0]
        try setup.signIn(test)
        try setup.tools.write(scenario: StandInScenario(gateFile: "never-opened"))
        let started = ContinuousClock.now
        let ran = try await setup.driver(test, timeout: 30).execute(ToolRunRequest(
            prompt: Self.reviewPrompt, folder: setup.work, purpose: .check, timeLimitSeconds: 1))
        guard case .failed(.timedOut, _) = ran else {
            Issue.record("expected the run to time out, got \(ran)")
            return
        }
        #expect(ContinuousClock.now - started < .seconds(15), "the job's one second, not the configuration's 30")
        // A job's limit longer than the configuration's is the configuration's.
        let gemini = Self.cases[2]
        try setup.signIn(gemini)
        let answered = try await setup.driver(gemini, timeout: 60).execute(ToolRunRequest(
            prompt: Prompts.ready, folder: setup.work, purpose: .check, timeLimitSeconds: 600))
        #expect(answered == .answered(ToolAnswer(text: "ready\n", tokens: gemini.tokens)))
        let argv = try setup.lastCall().argv
        let index = try #require(argv.firstIndex(of: "--print-timeout"))
        #expect(argv.dropFirst(index + 1).first == "60s")
    }

    @Test("the provider's shape is chosen by the provider")
    func shapes() {
        #expect(ProviderShapes.shape(for: .claude) is ClaudeDriver)
        #expect(ProviderShapes.shape(for: .codex) is CodexDriver)
        #expect(ProviderShapes.shape(for: .gemini) is AntigravityDriver)
        #expect(ProviderShapes.shape(for: .grok) is GrokDriver)
        #expect(ProviderShapes.shape(for: .claudeApi) == nil)
    }
}

@Suite("Probe", .timeLimit(.minutes(Patience.minutes(1))))
struct ProbeTests {
    @Test("the probe runs the test prompt once and exits 0 when the tool answers ready")
    func ready() async throws {
        let setup = try DriverTests.Setup()
        let test = DriverTests.cases[0]
        try setup.signIn(test)
        let code = await Probe.run(
            environment: setup.environment(test), log: Log(component: "probe-test", write: { _ in }))
        #expect(code == 0)
        let call = try setup.lastCall()
        #expect(call.argv.dropFirst().first == Prompts.ready)
        #expect(call.argv.contains("--tools"))
        #expect(call.cwd != setup.work.path)
    }

    @Test("the probe exits 1 when the tool is signed out, or the configuration is incomplete")
    func notReady() async throws {
        let setup = try DriverTests.Setup()
        let test = DriverTests.cases[1]
        let log = Log(component: "probe-test", write: { _ in })
        #expect(await Probe.run(environment: setup.environment(test), log: log) == 1)
        var incomplete = setup.environment(test)
        incomplete["LEVERAGE_TOOL_PATH"] = nil
        #expect(await Probe.run(environment: incomplete, log: log) == 1)
    }

    @Test("the probe's tool run is limited to 120 seconds unless the environment says otherwise")
    func probeLimit() async throws {
        let setup = try DriverTests.Setup()
        let test = DriverTests.cases[2]
        try setup.signIn(test)
        var environment = setup.environment(test)
        environment["LEVERAGE_TOOL_TIMEOUT_SECONDS"] = nil
        #expect(await Probe.run(environment: environment, log: Log(component: "probe-test", write: { _ in })) == 0)
        #expect(try setup.lastCall().argv.suffix(2) == ["--print-timeout", "120s"])
    }

    @Test("the probe's log never carries the tool's output")
    func quiet() async throws {
        let setup = try DriverTests.Setup()
        let test = DriverTests.cases[0]
        try setup.signIn(test)
        let lines = LockedLines()
        _ = await Probe.run(environment: setup.environment(test), log: Log(component: "probe-test", write: lines.add))
        #expect(!lines.all.contains { $0.contains(StandIns.statusEmail) || $0.contains("ready\"") })
    }
}

final class LockedLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    var add: @Sendable (String) -> Void { { [self] line in lock.withLock { lines.append(line) } } }
    var all: [String] { lock.withLock { lines } }
}
