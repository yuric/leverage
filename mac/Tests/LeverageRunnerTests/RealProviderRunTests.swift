import Foundation
import LeverageKit
import Testing

@testable import LeverageRunner

/// The developer check with a real provider's tool (plan PV-6, WP21), run
/// only by `scripts/real_provider_run.sh`, which sets the variables below.
/// It never runs in CI, and with none of them set it does not run at all.
///
/// One build prompt goes through the runner's own path: `ToolConfiguration`
/// from an environment, the builder prompt of `Prompts.builder`, and
/// `ProcessToolDriver.run(prompt:in:purpose: .build)`, so the tool gets
/// exactly the arguments and the allow-listed environment a builder's run
/// gives it. The one criterion asks for a file the stand-in builder also
/// writes (`criterion-1.txt`, with the word "done"). Before the prompt, the
/// catalog's version command, and its status command where the provider has
/// one, run under the same environment; a status that says signed out ends
/// the check with no prompt. The tool's output is never written anywhere:
/// only the facts in `RealProviderRun.Result`.
///
/// The variables, all set by the script:
/// - `LEVERAGE_REAL_PROVIDER`: the provider (the script's switch);
/// - `LEVERAGE_REAL_PROVIDER_RESULT`: the file the result is written to;
/// - `LEVERAGE_REAL_PROVIDER_TOOL`: the tool's absolute path;
/// - `LEVERAGE_REAL_PROVIDER_FOLDER`: a new, empty folder to run in;
/// - `LEVERAGE_REAL_PROVIDER_TIMEOUT`: the tool run's limit in seconds;
/// - `LEVERAGE_REAL_PROVIDER_SUPPORT`: a support folder of the check's own;
/// - `LEVERAGE_REAL_PROVIDER_MODEL`, `LEVERAGE_REAL_PROVIDER_EFFORT`: optional;
/// - `LEVERAGE_DEV_TOOL_LOGIN`: passed on as it is, so that Claude and Codex
///   run on the sign-in the tool holds for this Mac user.
@Suite(
    "Real provider run",
    .enabled(if: RealProviderRun.Inputs(environment: ProcessInfo.processInfo.environment) != nil))
struct RealProviderRunTests {
    @Test("one build prompt through the runner's driver")
    func realProviderRun() async throws {
        let inputs = try #require(RealProviderRun.Inputs(environment: ProcessInfo.processInfo.environment))
        let result = await RealProviderRun.run(inputs)
        try Data(result.text.utf8).write(to: inputs.resultFile)
    }
}

enum RealProviderRun {
    static let expectedFile = "criterion-1.txt"
    static let expectedWord = "done"
    static let criterion = "Create a file named \(expectedFile) in this folder that contains the word \(expectedWord)."
    static let commandLimit = Duration.seconds(30)

    struct Inputs {
        let provider: String
        let resultFile: URL
        let toolPath: String
        let folder: URL
        /// The environment `ToolConfiguration` reads: this process's own
        /// without any Leverage variable, then only the check's.
        let environment: [String: String]

        init?(environment process: [String: String]) {
            guard process["CI"] == nil,
                  let provider = process[EnvironmentKeys.realProvider], !provider.isEmpty,
                  let result = process["LEVERAGE_REAL_PROVIDER_RESULT"], result.hasPrefix("/"),
                  let tool = process["LEVERAGE_REAL_PROVIDER_TOOL"], tool.hasPrefix("/"),
                  let folder = process["LEVERAGE_REAL_PROVIDER_FOLDER"], folder.hasPrefix("/"),
                  let timeout = process["LEVERAGE_REAL_PROVIDER_TIMEOUT"],
                  let support = process["LEVERAGE_REAL_PROVIDER_SUPPORT"], support.hasPrefix("/")
            else { return nil }
            var environment = process.filter { !$0.key.hasPrefix("LEVERAGE_") }
            environment[EnvironmentKeys.provider] = provider
            environment[EnvironmentKeys.toolPath] = tool
            environment[EnvironmentKeys.toolTimeoutSeconds] = timeout
            environment[EnvironmentKeys.supportDir] = support
            environment[EnvironmentKeys.model] = process["LEVERAGE_REAL_PROVIDER_MODEL"]
            environment[EnvironmentKeys.effort] = process["LEVERAGE_REAL_PROVIDER_EFFORT"]
            environment[EnvironmentKeys.devToolLogin] = process[EnvironmentKeys.devToolLogin]
            self.provider = provider
            resultFile = URL(fileURLWithPath: result)
            toolPath = tool
            self.folder = URL(fileURLWithPath: folder, isDirectory: true)
            self.environment = environment
        }
    }

    struct Result {
        var provider: String
        var tool = "unknown"
        var toolVersion = "unknown"
        /// `passed`, `failed` or `skipped: not signed in`.
        var outcome = "failed"
        /// Why it failed, in the runner's own words; never the tool's output.
        var reason: String?
        var exitStatus = "not run"
        var expectedFile = false
        /// The builder's marker line: `evidence`, `cannot` or `none`.
        var answerLine = "none"
        var tokens = 0
        var seconds = 0.0

        var text: String {
            var lines = [
                "provider: \(provider)",
                "tool: \(tool)",
                "tool_version: \(toolVersion)",
                "outcome: \(outcome)",
            ]
            if let reason { lines.append("reason: \(reason)") }
            lines += [
                "exit_status: \(exitStatus)",
                "expected_file: \(expectedFile ? "yes" : "no") (\(RealProviderRun.expectedFile) with the word "
                    + "\(RealProviderRun.expectedWord))",
                "answer_line: \(answerLine)",
                "tokens: \(tokens)",
                "seconds: \(String(format: "%.2f", seconds))",
            ]
            return lines.joined(separator: "\n") + "\n"
        }
    }

    static func run(_ inputs: Inputs) async -> Result {
        var result = Result(provider: inputs.provider)
        let configuration: ToolConfiguration
        do {
            configuration = try ToolConfiguration(environment: inputs.environment)
        } catch {
            result.reason = "the runner refused the configuration: \(error)"
            return result
        }
        let entry = configuration.entry
        result.tool = entry.toolName
        guard (inputs.toolPath as NSString).lastPathComponent == entry.toolName else {
            result.reason = "the tool found is not \(entry.toolName)"
            return result
        }
        // The version and the status run beside the work folder, which stays
        // empty for the prompt.
        let beside = inputs.folder.deletingLastPathComponent().path
        result.toolVersion = await version(configuration, in: beside)

        switch await signedIn(configuration, in: beside) {
        case .some(false):
            result.outcome = "skipped: not signed in"
            return result
        case .none:
            result.reason = "the status command did not answer"
            return result
        case .some(true):
            break
        }

        let prompt = Prompts.builder(
            number: 1, criterion: checkCriterion, briefing: checkBriefing, reviewNotes: [])
        let clock = ContinuousClock()
        let started = clock.now
        do {
            let driver = try ProcessToolDriver(tool: configuration)
            let answer = try await driver.run(prompt: prompt, in: inputs.folder, purpose: .build)
            result.exitStatus = "0"
            result.tokens = answer.tokens
            switch AnswerParser.builder(answer.text) {
            case .evidence: result.answerLine = "evidence"
            case .cannot: result.answerLine = "cannot"
            case .none: result.answerLine = "none"
            }
        } catch let failure as ToolFailure {
            result.exitStatus = exitStatus(failure)
            result.reason = failure.description
        } catch {
            result.reason = "the run stopped: \(String(describing: type(of: error)))"
        }
        let elapsed = clock.now - started
        result.seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18

        let file = inputs.folder.appendingPathComponent(expectedFile)
        if let data = try? Data(contentsOf: file), let text = String(data: data, encoding: .utf8) {
            result.expectedFile = text.lowercased().contains(expectedWord)
        }
        if result.exitStatus == "0", result.reason == nil {
            if result.expectedFile {
                result.outcome = "passed"
            } else {
                result.reason = "the tool answered, but \(expectedFile) with the word \(expectedWord) is not there"
            }
        }
        return result
    }

    static let checkTaskID = UUID(uuidString: "00000000-0000-4000-8000-00000000c0de")!
    static let checkCriterion = Criterion(
        id: UUID(uuidString: "00000000-0000-4000-8000-00000000c001")!, taskID: checkTaskID, position: 1,
        text: criterion, kind: .build, state: .open)
    static let checkBriefing = Briefing(
        hash: "developer-check",
        versions: BriefingVersions(roleFileVersion: "0.0.0", contractVersion: 1),
        roleFile: "You build what the contract asks, in the folder you are run in.",
        contract: BriefingContract(
            contractVersion: 1, title: "Write the Leverage tool check file",
            details: "A file shows that this tool can work in a folder for Leverage.", criteria: [checkCriterion]))

    static func exitStatus(_ failure: ToolFailure) -> String {
        switch failure {
        case .exited(let code): "\(code)"
        case .signaled(let signal): "signal \(signal)"
        case .timedOut: "timed out"
        case .couldNotStart: "did not start"
        case .reportedError, .unreadableOutput: "0"
        }
    }

    /// The first line of the catalog's version command, printable and short.
    static func version(_ configuration: ToolConfiguration, in folder: String) async -> String {
        guard let output = try? await Subprocess.run(SubprocessRequest(
            executable: configuration.toolPath, arguments: configuration.entry.version.value,
            environment: configuration.toolEnvironment, workingDirectory: folder, timeLimit: commandLimit,
            gracePeriod: .seconds(2))),
            output.succeeded
        else { return "unknown" }
        let line = String(decoding: output.standardOutput, as: UTF8.self)
            .split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let printable = String(line.unicodeScalars.filter { $0.value >= 0x20 && $0.value < 0x7f }.map(Character.init))
        let trimmed = printable.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "unknown" : String(trimmed.prefix(120))
    }

    /// What the catalog's status command says (the helper's reading,
    /// `ToolStatus.reads`); true with no status command, where the prompt's
    /// own answer is the check; nil when the command did not answer. The
    /// output is read for the one fact and dropped.
    static func signedIn(_ configuration: ToolConfiguration, in folder: String) async -> Bool? {
        let check = configuration.entry.status.value
        guard let arguments = check.arguments else { return true }
        if case .testPrompt = check.reading { return true }
        guard let output = try? await Subprocess.run(SubprocessRequest(
            executable: configuration.toolPath, arguments: arguments,
            environment: configuration.toolEnvironment, workingDirectory: folder, timeLimit: commandLimit,
            gracePeriod: .seconds(2))),
            output.endedBy == nil
        else { return nil }
        switch check.reading {
        case .jsonField(let field):
            let object = try? JSONDecoder().decode(JSONValue.self, from: output.standardOutput)
            return object?[field] == .bool(true)
        case .signedOutText(let text):
            let said = String(decoding: output.standardOutput + output.standardError, as: UTF8.self)
            return output.termination == .exited(0) && !said.contains(text)
        case .testPrompt:
            return true
        }
    }
}
