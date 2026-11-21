import Foundation
import LeverageKit
import LeverageTestSupport
import Testing

@testable import LeverageRunner

// `LeverageRunner eval` (milestone 4 plan §2.2, RV-3, RV-6, §2.4): each
// case's input through CheckJob's prompt, tool run and parser, with
// CheckJob's own second run turned off, one line of JSON per case. Every
// tool here is a copy of the stand-ins: no case sets LEVERAGE_EVAL_REAL to
// anything but a refusal's, and none of those starts a tool.
@Suite("EvalRunTests", .serialized)
struct EvalRunTests {
    static let suite = "specific-details"
    static let approvalSuite = "approves-actions"
    static let approvalAction = "Send the made-up receipt to the test mailbox."

    final class Setup: @unchecked Sendable {
        let folder: TemporaryFolder
        let tools: StandInTools
        let account: URL
        let inputs: URL
        let out: URL
        private let lock = NSLock()
        private var printed: [String] = []

        init(scenario: [String: Any] = [:], cases: Int = 3, signIn: [String] = ["claude"]) throws {
            folder = try TemporaryFolder(prefix: "leverage-eval")
            tools = try StandIns.copy(into: folder.url)
            account = try folder.folder("account")
            inputs = folder.path("inputs.json")
            out = folder.path("verdicts.jsonl")
            try FileManager.default.createDirectory(at: tools.state, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: scenario)
                .write(to: tools.state.appendingPathComponent("scenario.json"))
            for tool in signIn {
                try tools.signIn(tool, accountFolder: ["claude", "codex"].contains(tool) ? account : nil)
            }
            try writeInputs(ids: (1...cases).map { String(format: "%02d-made-up-case", $0) })
        }

        func writeInputs<Input: Encodable>(
            ids: [String], suite: String, makeInput: () -> Input
        ) throws {
            let encoder = JSONEncoder()
            let entries = try ids.map { id -> [String: Any] in
                let input = try JSONSerialization.jsonObject(with: encoder.encode(makeInput()))
                return ["id": id, "input": input]
            }
            try JSONSerialization.data(withJSONObject: ["suite": suite, "cases": entries]).write(to: inputs)
        }

        func writeInputs(ids: [String], suite: String = EvalRunTests.suite) throws {
            try writeInputs(ids: ids, suite: suite) { JobFixture.checkInput() }
        }

        func writeApprovalInputs(count: Int) throws {
            let check = JobFixture.checkMaterial()
            let description = EvalRunTests.approvalAction
            let contract = ActionJobContract(
                title: check.contract.title, goal: check.contract.goal, details: check.contract.details,
                criteria: check.contract.criteria, actions: [.init(kind: .send, description: description)])
            let material = ApprovalMaterial(
                roleFile: check.roleFile, instruction: check.instruction,
                action: .init(kind: .send, description: description, position: 1), contract: contract,
                quoted: [.init(label: .evidence, text: JobFixture.evidence)])
            try writeInputs(
                ids: (1...count).map { String(format: "%02d-made-up-case", $0) },
                suite: EvalRunTests.approvalSuite
            ) {
                ApprovalJobInput(actionID: UUID(), ruleCheckID: UUID(), taskID: UUID(), material: material)
            }
        }

        /// A stand-in run's environment, with values of the parent that must
        /// not reach the tool.
        func environment(_ extra: [String: String] = [:]) -> [String: String] {
            var values = [
                "LEVERAGE_EVAL": EvalRunTests.suite,
                "LEVERAGE_TOOL_DIR": tools.bin.path,
                "HOME": folder.url.path,
                "TMPDIR": folder.url.path,
                "LANG": "en_US.UTF-8",
                "USER": "standin",
                "FOO": "not for the tool",
                "LEVERAGE_SEAT_TOKEN": DriverTests.fakeSeatToken,
                "CLAUDE_CONFIG_DIR": "/made-up/the-parents-claude-folder",
                "CODEX_HOME": "/made-up/the-parents-codex-folder",
            ]
            values.merge(extra) { _, new in new }
            return values
        }

        func arguments(provider: String = "claude", accountFolder: Bool = true) -> [String] {
            var arguments = ["--inputs", inputs.path, "--provider", provider, "--out", out.path]
            if accountFolder { arguments += ["--account-folder", account.path] }
            return arguments
        }

        func run(_ arguments: [String]? = nil, environment: [String: String]? = nil) async -> Int32 {
            await EvalRun.run(
                arguments: arguments ?? self.arguments(), environment: environment ?? self.environment(),
                write: { [self] line in lock.withLock { printed.append(line) } })
        }

        var lines: [String] { lock.withLock { printed } }

        func results() throws -> [[String: Any]] {
            try String(contentsOf: out, encoding: .utf8).split(separator: "\n").map {
                try #require(try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
            }
        }

        /// The stand-in runs that were prompts: not the version command.
        func prompts() throws -> [StandInCall] {
            try tools.calls().filter { $0.argv != ["--version"] }
        }
    }

    static func string(_ value: Any?) -> String? { value as? String }
    static func int(_ value: Any?) -> Int? { (value as? NSNumber)?.intValue ?? value as? Int }

    // MARK: - One line per case

    @Test("one line per case: the id, the verdict, the reason, tokens, seconds, the tool's version and model")
    func oneLinePerCase() async throws {
        let setup = try Setup(scenario: ["check_verdicts": ["PASSED", "FAILED", "PASSED"]])
        #expect(await setup.run() == 0)

        let results = try setup.results()
        try #require(results.count == 3)
        #expect(results.map { Self.string($0["case"]) } == ["01-made-up-case", "02-made-up-case", "03-made-up-case"])
        #expect(results.map { Self.string($0["verdict"]) } == ["passed", "failed", "passed"])
        #expect(results.map { Self.string($0["reason"]) }
            == ["The stand-in passed it.", "The stand-in failed it.", "The stand-in passed it."])
        #expect(results.map { Self.int($0["tokens"]) } == [150, 150, 150])
        #expect(results.map { Self.int($0["tool_runs"]) } == [1, 1, 1])
        #expect(results.allSatisfy { (($0["seconds"] as? NSNumber)?.doubleValue ?? -1) >= 0 })
        #expect(results.allSatisfy { Self.string($0["tool_version"]) == "0.0.1 (Claude Code stand-in)" })
        #expect(results.allSatisfy { Self.string($0["model"]) == "the tool's default" })
        #expect(try setup.prompts().count == 3)
    }

    @Test("each prompt is CheckJob's frame, run in check mode in a new empty folder that is removed after it")
    func checkJobsPrompt() async throws {
        let setup = try Setup(cases: 2)
        #expect(await setup.run() == 0)

        let prompts = try setup.prompts()
        try #require(prompts.count == 2)
        for call in prompts {
            let prompt = try #require(call.argv.dropFirst().first)
            #expect(prompt.hasPrefix("LEVERAGE CHECK\n"))
            #expect(prompt.contains(JobFixture.goal))
            #expect(call.argv.suffix(2) == ["--tools", ""])
            #expect(!FileManager.default.fileExists(atPath: call.cwd))
        }
        #expect(Set(prompts.map(\.cwd)).count == 2)
    }

    // MARK: - No verdict, retries and the ceiling

    @Test("a case with no verdict is run once more, then is none: two tool runs, not four")
    func noVerdictAfterOneRetry() async throws {
        let setup = try Setup(scenario: ["check_verdicts": ["NONE", "NONE", "PASSED"]], cases: 2)
        #expect(await setup.run() == 0)

        let results = try setup.results()
        try #require(results.count == 2)
        #expect(Self.string(results[0]["verdict"]) == "none")
        #expect(results[0]["reason"] is NSNull)
        #expect(Self.int(results[0]["tool_runs"]) == 2)
        #expect(Self.int(results[0]["tokens"]) == 300)
        #expect(Self.string(results[1]["verdict"]) == "passed")
        #expect(Self.int(results[1]["tool_runs"]) == 1)
        #expect(try setup.prompts().count == 3)
    }

    @Test("a verdict on the second run counts")
    func verdictOnTheRetry() async throws {
        let setup = try Setup(scenario: ["check_verdicts": ["NONE", "FAILED"]], cases: 1)
        #expect(await setup.run() == 0)

        let results = try setup.results()
        #expect(results.map { Self.string($0["verdict"]) } == ["failed"])
        #expect(results.map { Self.int($0["tool_runs"]) } == [2])
    }

    @Test("no more than 6 cases are run again")
    func atMostSixRetries() async throws {
        let setup = try Setup(scenario: ["check_verdicts": Array(repeating: "NONE", count: 40)], cases: 8)
        #expect(await setup.run() == 0)

        let results = try setup.results()
        try #require(results.count == 8)
        #expect(results.map { Self.int($0["tool_runs"]) } == [2, 2, 2, 2, 2, 2, 1, 1])
        #expect(results.allSatisfy { Self.string($0["verdict"]) == "none" })
        #expect(try setup.prompts().count == 14)
    }

    @Test("it stops for good at 30 tool runs; the cases it did not reach are none, with no tool run")
    func atMostThirtyToolRuns() async throws {
        let setup = try Setup(scenario: ["check_verdicts": Array(repeating: "NONE", count: 60)], cases: 26)
        #expect(await setup.run() == 0)

        let results = try setup.results()
        try #require(results.count == 26)
        #expect(results.map { Self.int($0["tool_runs"]) } == Array(repeating: 2, count: 6) + Array(repeating: 1, count: 18)
            + [0, 0])
        #expect(results.allSatisfy { Self.string($0["verdict"]) == "none" })
        #expect(results.suffix(2).allSatisfy { ($0["not_reached"] as? Bool) == true })
        #expect(try setup.prompts().count == 30)
    }

    // MARK: - Approval eval

    @Test("the approval eval resolves the stand-in without starting it")
    func resolveApprovalTool() async throws {
        let setup = try Setup()
        let status = await setup.run(
            ["--provider", "claude", "--resolve-only"], environment: setup.environment(["LEVERAGE_EVAL": Self.approvalSuite]))
        #expect(status == 0)
        #expect(setup.lines == ["eval: claude: tool \(setup.tools.tool("claude").path)"])
        #expect(try setup.tools.calls().isEmpty)
    }

    @Test("approval runs use the production prompt and decision parser in check mode")
    func approvalDecisions() async throws {
        let setup = try Setup(scenario: ["approval_decisions": ["APPROVE", "STOP", "NONE", "ASK_OWNER"]])
        try setup.writeApprovalInputs(count: 3)
        try #require(await setup.run(environment: setup.environment(["LEVERAGE_EVAL": Self.approvalSuite])) == 0)

        let results = try setup.results()
        try #require(results.count == 3)
        #expect(results.map { Self.string($0["decision"]) } == ["approve", "stop", "ask_owner"])
        #expect(results.allSatisfy { $0["verdict"] == nil })
        #expect(results[1]["reason"] as? String == "The stand-in stopped it.")
        #expect(results.map { Self.int($0["tool_runs"]) } == [1, 1, 2])
        #expect(results.map { Self.int($0["tokens"]) } == [150, 150, 300])
        let prompts = try setup.prompts()
        try #require(prompts.count == 4)
        for call in prompts {
            let prompt = try #require(call.argv.dropFirst().first)
            #expect(prompt.hasPrefix("LEVERAGE APPROVAL\n"))
            #expect(prompt.contains(Self.approvalAction))
            #expect(prompt.contains(JobFixture.evidence))
            #expect(call.argv.suffix(2) == ["--tools", ""])
            #expect(!FileManager.default.fileExists(atPath: call.cwd))
        }
        #expect(Set(prompts.map(\.cwd)).count == 4)
    }

    @Test("two unreadable approval replies leave no decision and the next case still runs")
    func approvalRetryStops() async throws {
        let setup = try Setup(scenario: ["approval_decisions": ["NONE", "NONE", "STOP"]])
        try setup.writeApprovalInputs(count: 2)
        try #require(await setup.run(environment: setup.environment(["LEVERAGE_EVAL": Self.approvalSuite])) == 0)

        let results = try setup.results()
        try #require(results.count == 2)
        #expect(results.map { Self.string($0["decision"]) } == ["none", "stop"])
        #expect(results[0]["reason"] is NSNull)
        #expect(results.map { Self.int($0["tool_runs"]) } == [2, 1])
        #expect(results.map { Self.int($0["tokens"]) } == [300, 150])
        #expect(try setup.prompts().count == 3)
    }

    @Test("approval evals stop at their tool-run and retry ceilings", arguments: [36, 12])
    func approvalCeilings(maximumToolRuns: Int) async throws {
        let retries = maximumToolRuns == 36 ? 6 : 2
        let setup = try Setup(scenario: ["approval_decisions": Array(repeating: "NONE", count: 60)])
        try setup.writeApprovalInputs(count: maximumToolRuns - retries + 2)
        let environment = setup.environment([
            "LEVERAGE_EVAL": Self.approvalSuite,
            "LEVERAGE_EVAL_MAX_TOOL_RUNS": String(maximumToolRuns),
            "LEVERAGE_EVAL_MAX_SECOND_TRIES": String(retries),
        ])
        try #require(await setup.run(environment: environment) == 0)

        let results = try setup.results()
        let attempts = Array(repeating: 2, count: retries)
            + Array(repeating: 1, count: maximumToolRuns - 2 * retries) + [0, 0]
        #expect(results.map { Self.int($0["tool_runs"]) } == attempts)
        #expect(results.allSatisfy { Self.string($0["decision"]) == "none" })
        #expect(results.suffix(2).allSatisfy { ($0["not_reached"] as? Bool) == true })
        #expect(try setup.prompts().count == maximumToolRuns)
    }

    @Test("out-of-range or malformed eval ceilings are refused before the tool starts",
          arguments: [("37", "6"), ("36", "7"), ("0", "0"), ("12", "-1"), ("12", "two")])
    func refusesInvalidCeilings(toolRuns: String, retries: String) async throws {
        let setup = try Setup()
        try setup.writeApprovalInputs(count: 1)
        let environment = setup.environment([
            "LEVERAGE_EVAL": Self.approvalSuite,
            "LEVERAGE_EVAL_MAX_TOOL_RUNS": toolRuns,
            "LEVERAGE_EVAL_MAX_SECOND_TRIES": retries,
        ])
        #expect(await setup.run(environment: environment) == 2)
        #expect(setup.lines.contains { $0.contains("LEVERAGE_EVAL_MAX_") })
        #expect(try setup.tools.calls().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: setup.out.path))
    }

    // MARK: - The tool and its environment

    @Test("the resolved tool's path is printed before the first case")
    func printsTheToolFirst() async throws {
        let setup = try Setup(cases: 2)
        #expect(await setup.run() == 0)

        let lines = setup.lines
        let first = try #require(lines.first)
        #expect(first == "eval: claude: tool \(setup.tools.tool("claude").path)")
        let firstCase = try #require(lines.firstIndex { $0.contains("01-made-up-case") })
        #expect(firstCase > 0)
        #expect(!lines.joined().contains("The stand-in passed it."))
    }

    @Test("--resolve-only prints the tool and runs nothing")
    func resolveOnly() async throws {
        let setup = try Setup()
        #expect(await setup.run(["--provider", "codex", "--resolve-only"]) == 0)

        #expect(setup.lines == ["eval: codex: tool \(setup.tools.tool("codex").path)"])
        #expect(try setup.tools.calls().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: setup.out.path))
    }

    @Test("the Gemini tool is agy, found only in LEVERAGE_TOOL_DIR")
    func geminiIsAgy() async throws {
        let setup = try Setup(cases: 1, signIn: ["agy"])
        #expect(await setup.run(setup.arguments(provider: "gemini", accountFolder: false)) == 0)

        #expect(setup.lines.first == "eval: gemini: tool \(setup.tools.tool("agy").path)")
        #expect(try setup.results().map { Self.string($0["verdict"]) } == ["passed"])
    }

    @Test("--account-folder reaches the tool as its account-folder variable, and nothing else of the parent's does",
          arguments: ["claude", "codex"])
    func accountFolder(provider: String) async throws {
        let setup = try Setup(cases: 1, signIn: [provider])
        #expect(await setup.run(setup.arguments(provider: provider)) == 0)

        let call = try #require(try setup.prompts().first)
        let variable = provider == "claude" ? "CLAUDE_CONFIG_DIR" : "CODEX_HOME"
        #expect(call.env[variable] == setup.account.path)
        #expect(call.env["FOO"] == nil)
        #expect(call.env.keys.allSatisfy { !$0.hasPrefix("LEVERAGE_") })
        #expect(!call.env.values.contains(DriverTests.fakeSeatToken))
        #expect(!call.env.values.contains { $0.contains("the-parents") })
        #expect(try setup.results().map { Self.string($0["verdict"]) } == ["passed"])
    }

    @Test("a tool missing from LEVERAGE_TOOL_DIR is not looked for anywhere else, PATH included")
    func missingTool() async throws {
        let setup = try Setup()
        let elsewhere = try setup.folder.folder("elsewhere")
        try FileManager.default.copyItem(at: setup.tools.tool("claude"), to: elsewhere.appendingPathComponent("claude"))
        try FileManager.default.removeItem(at: setup.tools.tool("claude"))
        let home = try setup.folder.folder("home")
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".local/bin"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: elsewhere.appendingPathComponent("claude"), to: home.appendingPathComponent(".local/bin/claude"))
        #expect(await setup.run(environment: setup.environment(["PATH": elsewhere.path, "HOME": home.path])) == 1)
        #expect(try setup.tools.calls().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: setup.out.path))
    }

    // MARK: - Refusals: exit 2, nothing started

    static let refusals: [(String, [String: String?])] = [
        ("without LEVERAGE_EVAL", ["LEVERAGE_EVAL": nil]),
        ("with another suite", ["LEVERAGE_EVAL": "approvals"]),
        ("with neither LEVERAGE_TOOL_DIR nor LEVERAGE_EVAL_REAL", ["LEVERAGE_TOOL_DIR": nil]),
        ("with both", ["LEVERAGE_EVAL_REAL": "1"]),
        ("with LEVERAGE_EVAL_REAL set to something other than 1", ["LEVERAGE_TOOL_DIR": nil, "LEVERAGE_EVAL_REAL": "yes"]),
        ("on the real path with CI set", ["LEVERAGE_TOOL_DIR": nil, "LEVERAGE_EVAL_REAL": "1", "CI": "true"]),
        ("with a LEVERAGE_TOOL_DIR that is not a copy of the stand-ins", ["LEVERAGE_TOOL_DIR": "/usr/bin"]),
        ("with a LEVERAGE_TOOL_DIR that is not absolute", ["LEVERAGE_TOOL_DIR": "StandIns/bin"]),
    ]

    /// Each refusal is asked with an inputs file that does not exist: were a
    /// guard broken, the run would stop at the inputs (exit 1) before any
    /// tool is looked for, so no test can reach a real tool on the real path.
    @Test("it refuses to start, with exit 2, and starts no tool", arguments: 0..<refusals.count)
    func refuses(index: Int) async throws {
        let (name, changes) = Self.refusals[index]
        let setup = try Setup()
        var environment = setup.environment()
        for (key, value) in changes { environment[key] = value }
        var arguments = setup.arguments()
        arguments[1] = setup.folder.path("no-such-inputs.json").path
        #expect(await setup.run(arguments, environment: environment) == 2, "\(name)")
        #expect(try setup.tools.calls().isEmpty, "\(name)")
        #expect(!FileManager.default.fileExists(atPath: setup.out.path), "\(name)")
    }

    @Test("an inputs file of another suite, an unknown provider or a missing argument is refused",
          arguments: ["suite", "provider", "inputs", "out", "unknown"])
    func refusesArguments(what: String) async throws {
        let setup = try Setup()
        var arguments = setup.arguments()
        switch what {
        case "suite": try setup.writeInputs(ids: ["01-made-up-case"], suite: "approvals")
        case "provider": arguments[3] = "chatbot"
        case "inputs": arguments.removeSubrange(0...1)
        case "out": arguments.removeSubrange(4...5)
        default: arguments.append("--fast")
        }
        #expect(await setup.run(arguments) == 2)
        #expect(try setup.tools.calls().isEmpty)
    }

    // MARK: - The canary

    @Test("a stand-in told to give the canary away puts it in a reason, and the scorer counts it as a leak")
    func canaryLeak() async throws {
        let canaryFolder = try TemporaryFolder(prefix: "leverage-eval-canary")
        let word = "zirbelmonk"
        let canary = canaryFolder.path("word.txt")
        try Data("\(word)\n".utf8).write(to: canary)
        let setup = try Setup(scenario: ["check_reason_from_file": canary.path], cases: 1)
        let suite = EvalRunTests.scoringSuite
        let ids = try FileManager.default.contentsOfDirectory(atPath: suite.appendingPathComponent("cases").path)
            .filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }.sorted()
        try #require(ids.count == 24)
        try setup.writeInputs(ids: ids)
        #expect(await setup.run() == 0)

        let results = try setup.results()
        try #require(results.count == 24)
        #expect(results.allSatisfy { Self.string($0["reason"]) == word })

        let scored = try EvalRunTests.score(suite: suite, verdicts: setup.out, canary: word)
        #expect(Self.int(scored["canary_leaks"]) == 24)
        #expect((scored["met_bar"] as? Bool) == false)
    }

    /// The scorer's fixture suite: 24 made-up cases.
    static let scoringSuite = StandIns.sourceFolder  // mac/Tests/StandIns
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("scripts/fixtures/evals/suite", isDirectory: true)

    /// `python3 -I scripts/eval_score.py score`, as scripts/eval_rule.sh runs it.
    static func score(suite: URL, verdicts: URL, canary: String) throws -> [String: Any] {
        let scorer = suite.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("eval_score.py")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-I", scorer.path, "score", "--suite", suite.path, "--verdicts", verdicts.path,
                             "--canary", canary]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
