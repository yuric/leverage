import Foundation
import LeverageKit

/// `LeverageRunner eval --inputs <file> --provider <name> --out <file>
/// [--account-folder <dir>] [--resolve-only]`: the eval suite's harness
/// (milestone 4 plan section 2.2, RV-3, RV-6, section 2.4). No seat, no
/// server.
///
/// Each case's input, which `api/script/evals/build_inputs.rb` built with
/// `JobInputs`, goes through `CheckJob`'s prompt, tool run (check mode, a
/// new empty folder, 120 seconds) and parser, with `CheckJob`'s own second
/// run turned off. A case with no verdict is run once more, for at most 6
/// cases, and then counts as `none`; at 30 tool runs it stops for good and
/// writes the cases it did not reach as `none`. One line of JSON per case
/// goes to `--out`: the case, the verdict (`passed`, `failed` or `none`),
/// the reason, the tokens, the seconds, the tool runs, the tool's version
/// and the model ("the tool's default": the drivers read no model name from
/// a tool's answer, and the run sets none).
///
/// It refuses to start (exit 2) unless `LEVERAGE_EVAL` names the suite and
/// exactly one of these holds: `LEVERAGE_TOOL_DIR` is set (a run against
/// the stand-ins, which must be a copy of `mac/Tests/StandIns`), or
/// `LEVERAGE_EVAL_REAL` is `1` (the managing agent's run, never with `CI`
/// set). The tool is found here, without `ToolLocator`, which is the
/// helper's: under `LEVERAGE_TOOL_DIR` alone on the stand-in path; on the
/// real path in the catalog's folders and then `PATH`'s, as `ToolLocator`
/// looks. Its path is printed before anything runs. `--account-folder` is
/// the provider's account-folder variable, the way a seat the app runs gets
/// it (CL-9), and the tool's environment is the catalog's allow-list
/// (CL-10): nothing else of this process's environment reaches it. On the
/// real path `LEVERAGE_DEV_TOOL_LOGIN=1`, which `scripts/eval_rule.sh` sets,
/// lets Claude or Codex use the sign-in it already holds (PV-6).
///
/// Exit 0 when every case has its line (whatever the verdicts), 1 when the
/// run could not be made (no tool, an unreadable inputs file), 2 for a
/// refused start. The lines it prints name the tool and each case's id and
/// verdict, never a prompt, an answer or a reason.
enum EvalRun {
    static let exitCode: Int32 = 2

    /// The suites this harness runs; `LEVERAGE_EVAL` names one.
    static let suites = ["specific-details"]
    /// RV-6: a full run of one model makes at most 30 tool runs, 6 of them
    /// second tries.
    static let maximumToolRuns = 30
    static let maximumSecondTries = 6
    /// Each tool run's limit (RV-6), as the probe's.
    static let toolRunSeconds = 120
    /// The model a line names when the tool reports none.
    static let defaultModel = "the tool's default"
    /// How long the tool's version command may take.
    static let versionTimeLimit: Duration = .seconds(30)
    /// The program the stand-in tools run, beside their `bin/`.
    static let standInProgram = "provider_tool.py"

    /// Each line it prints, to standard output.
    static let standardOutput: @Sendable (String) -> Void = { line in
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }

    static func run(
        arguments: [String], environment: [String: String], write: @escaping @Sendable (String) -> Void = standardOutput
    ) async -> Int32 {
        let options: Options
        let path: ToolSource
        do {
            options = try Options(arguments: arguments)
            path = try ToolSource(environment: environment)
        } catch let refusal as Refusal {
            write("eval: refused: \(refusal.reason)")
            return exitCode
        } catch {
            return exitCode
        }

        // The inputs are read before any tool is looked for, so that a run
        // that cannot be made stops before anything is resolved or started.
        var suite: Inputs?
        if !options.resolveOnly {
            do {
                suite = try Inputs.read(options.inputs)
            } catch {
                write("eval: the inputs file cannot be read (\(error))")
                return 1
            }
            if let name = suite?.suite, name != path.suite {
                write("eval: refused: the inputs are the suite \(name), not \(path.suite)")
                return exitCode
            }
        }

        guard let entry = ProviderCatalog.entry(for: options.provider.rawValue),
              let tool = resolve(entry, source: path, environment: environment) else {
            write("eval: \(options.provider.rawValue): no tool found \(path.where)")
            return 1
        }
        write("eval: \(options.provider.rawValue): tool \(tool)")
        guard let suite else { return 0 }

        let configuration: ToolConfiguration
        let driver: ProcessToolDriver
        do {
            configuration = try ToolConfiguration(
                environment: toolEnvironment(
                    environment, provider: options.provider, tool: tool, source: path,
                    accountFolder: options.accountFolder),
                defaultTimeout: toolRunSeconds)
            driver = try ProcessToolDriver(tool: configuration)
        } catch {
            write("eval: \(options.provider.rawValue): not started: \(error)")
            return 1
        }
        let version = await toolVersion(entry, configuration: configuration)
        write("eval: \(options.provider.rawValue): version \(version), \(suite.cases.count) cases")

        let base = configuration.parentEnvironment[EnvironmentKeys.tmpdir].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        let workRoot = base.appendingPathComponent("leverage-eval-\(UUID().uuidString.lowercased())", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: workRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try Data().write(to: URL(fileURLWithPath: options.out))
        } catch {
            write("eval: no folder for the runs, or the output cannot be written (\(error))")
            return 1
        }
        defer { try? FileManager.default.removeItem(at: workRoot) }

        let counting = CountingDriver(driver: driver, ceiling: maximumToolRuns)
        let context = FlowContext(
            api: NoServer(), driver: counting, timing: .standard, log: Log(component: "eval", write: { _ in }),
            state: RunnerState(), workRoot: workRoot, home: configuration.home,
            interruption: Interruption(provider: options.provider, hasCredential: false))
        let lines = Lines(path: options.out)
        var secondTries = 0
        for item in suite.cases {
            var line = Line(case: item.id, toolVersion: version)
            if counting.runs >= maximumToolRuns {
                line.notReached = true
            } else {
                let started = Date()
                let before = counting.runs
                var verdict = await check(item.input, context: context)
                if verdict == nil, secondTries < maximumSecondTries, counting.runs < maximumToolRuns {
                    secondTries += 1
                    verdict = await check(item.input, context: context)
                }
                line.verdict = verdict
                line.toolRuns = counting.runs - before
                line.tokens = counting.tokens(since: before)
                line.seconds = (Date().timeIntervalSince(started) * 1000).rounded() / 1000
            }
            do {
                try lines.append(line)
            } catch {
                write("eval: the output cannot be written (\(error))")
                return 1
            }
            write("eval: \(options.provider.rawValue): \(item.id): \(line.verdictWord) "
                + "(\(line.toolRuns) tool run\(line.toolRuns == 1 ? "" : "s"))")
        }
        write("eval: \(options.provider.rawValue): \(counting.runs) tool runs, \(secondTries) second tries")
        return 0
    }

    /// One run of `CheckJob` on the input, its own second run off: the
    /// verdict, or nil when none came.
    static func check(_ input: RuleCheckJobInput, context: FlowContext) async -> RuleCheckVerdict? {
        // The claim's due time leaves the tool its whole limit: CheckJob
        // ends the tool 10 seconds before it (RD-34).
        let claim = JobClaim(
            jobID: UUID(), kind: .ruleCheck, input: .ruleCheck(input),
            runDueAt: context.timing.now().addingTimeInterval(Double(toolRunSeconds) + CheckJob.endsBeforeDue + 1))
        guard case .result(let request)? = try? await CheckJob(context: context, allowsSecondRun: false)
            .run(claim, input: input),
            case .ruleCheck(let verdict) = request.result else { return nil }
        return verdict
    }

    // MARK: - The tool

    /// The first program of the tool's name in the folders `source` allows.
    static func resolve(_ entry: ProviderEntry, source: ToolSource, environment: [String: String]) -> String? {
        let home = environment[EnvironmentKeys.home] ?? NSHomeDirectory()
        let support = environment[EnvironmentKeys.supportDir].flatMap { $0.isEmpty ? nil : $0 }
            ?? "\(home)/Library/Application Support/leverage"
        var folders = ProviderCatalog.searchFolders(
            for: entry.id, home: home, supportFolder: support, toolDir: source.toolDir)
        if source.toolDir == nil {
            // The real path looks where ToolLocator looks: then PATH.
            for folder in (environment[EnvironmentKeys.path] ?? "").split(separator: ":").map(String.init)
            where folder.hasPrefix("/") && !folders.contains(folder) {
                folders.append(folder)
            }
        }
        for folder in folders {
            let candidate = URL(fileURLWithPath: folder).appendingPathComponent(entry.toolName).path
            var isFolder: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate, isDirectory: &isFolder), !isFolder.boolValue,
               FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    /// The environment `ToolConfiguration` reads for this run: this
    /// process's own variables without any of leverage's, and the run's.
    static func toolEnvironment(
        _ environment: [String: String], provider: Provider, tool: String, source: ToolSource, accountFolder: String?
    ) -> [String: String] {
        var values = environment.filter { !$0.key.hasPrefix("LEVERAGE_") }
        values[EnvironmentKeys.provider] = provider.rawValue
        values[EnvironmentKeys.toolPath] = tool
        values[EnvironmentKeys.toolTimeoutSeconds] = String(toolRunSeconds)
        if let support = environment[EnvironmentKeys.supportDir], !support.isEmpty {
            values[EnvironmentKeys.supportDir] = support
        }
        if let toolDir = source.toolDir {
            values[EnvironmentKeys.toolDir] = toolDir
        } else if environment[EnvironmentKeys.devToolLogin] == "1" {
            values[EnvironmentKeys.devToolLogin] = "1"
        }
        if let accountFolder { values[EnvironmentKeys.settingsDir] = accountFolder }
        return values
    }

    /// The first line of the tool's version command, on standard output or
    /// else standard error; "unknown" when it gives none.
    static func toolVersion(_ entry: ProviderEntry, configuration: ToolConfiguration) async -> String {
        guard let result = try? await Subprocess.run(SubprocessRequest(
            executable: configuration.toolPath, arguments: entry.version.value,
            environment: configuration.toolEnvironment, timeLimit: versionTimeLimit, gracePeriod: .seconds(2))),
            result.succeeded else { return "unknown" }
        for output in [result.standardOutput, result.standardError] {
            let text = String(decoding: output, as: UTF8.self)
            if let line = text.split(whereSeparator: \.isNewline).first?.trimmingCharacters(in: .whitespaces),
               !line.isEmpty {
                return String(line.prefix(200))
            }
        }
        return "unknown"
    }

    // MARK: - Pieces

    struct Refusal: Error {
        let reason: String
    }

    /// The arguments.
    struct Options {
        var inputs = ""
        var provider: Provider
        var out = ""
        var accountFolder: String?
        var resolveOnly = false

        init(arguments: [String]) throws {
            var values: [String: String] = [:]
            var resolveOnly = false
            var rest = arguments[...]
            while let flag = rest.popFirst() {
                switch flag {
                case "--resolve-only":
                    resolveOnly = true
                case "--inputs", "--provider", "--out", "--account-folder":
                    guard let value = rest.popFirst(), !value.isEmpty, !value.hasPrefix("--") else {
                        throw Refusal(reason: "\(flag) needs a value")
                    }
                    values[flag] = value
                default:
                    throw Refusal(reason: "unknown argument \(flag)")
                }
            }
            guard let name = values["--provider"] else { throw Refusal(reason: "--provider is missing") }
            guard let provider = Provider(rawValue: name), provider.facts.kind == .login,
                  ProviderShapes.shape(for: provider) != nil else {
                throw Refusal(reason: "\(name) is not a login this runner drives")
            }
            self.provider = provider
            self.resolveOnly = resolveOnly
            if resolveOnly { return }
            guard let inputs = values["--inputs"] else { throw Refusal(reason: "--inputs is missing") }
            guard let out = values["--out"] else { throw Refusal(reason: "--out is missing") }
            self.inputs = inputs
            self.out = out
            if let folder = values["--account-folder"] {
                var isFolder: ObjCBool = false
                guard folder.hasPrefix("/"), FileManager.default.fileExists(atPath: folder, isDirectory: &isFolder),
                      isFolder.boolValue else {
                    throw Refusal(reason: "--account-folder is not an absolute path to a folder")
                }
                accountFolder = folder
            }
        }
    }

    /// Where the tool may come from: the stand-ins, or the Mac's own tools.
    struct ToolSource {
        let suite: String
        /// The stand-ins' `bin/`; nil on the real path.
        let toolDir: String?

        init(environment: [String: String]) throws {
            func value(_ name: String) -> String? {
                environment[name].flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
            }
            guard let suite = value(EnvironmentKeys.eval), EvalRun.suites.contains(suite) else {
                throw Refusal(reason: "\(EnvironmentKeys.eval) must name the suite (\(EvalRun.suites.joined(separator: ", ")))")
            }
            let toolDir = value(EnvironmentKeys.toolDir)
            let real = value(EnvironmentKeys.evalReal)
            if let real, real != "1" {
                throw Refusal(reason: "\(EnvironmentKeys.evalReal) is 1 or unset")
            }
            switch (toolDir, real) {
            case (nil, nil):
                throw Refusal(reason: "set \(EnvironmentKeys.toolDir) (the stand-ins) or \(EnvironmentKeys.evalReal)=1")
            case (_?, _?):
                throw Refusal(reason: "\(EnvironmentKeys.toolDir) and \(EnvironmentKeys.evalReal) are both set")
            case (nil, _?):
                if value("CI") != nil { throw Refusal(reason: "CI is set; a run on real tools never runs in CI") }
            case (let folder?, nil):
                var isFolder: ObjCBool = false
                guard folder.hasPrefix("/"), FileManager.default.fileExists(atPath: folder, isDirectory: &isFolder),
                      isFolder.boolValue else {
                    throw Refusal(reason: "\(EnvironmentKeys.toolDir) is not an absolute path to a folder")
                }
                let program = URL(fileURLWithPath: folder).deletingLastPathComponent()
                    .appendingPathComponent(EvalRun.standInProgram).path
                guard FileManager.default.fileExists(atPath: program) else {
                    throw Refusal(reason: "\(EnvironmentKeys.toolDir) is not the bin/ of a copy of the stand-ins")
                }
            }
            self.suite = suite
            self.toolDir = toolDir
        }

        var `where`: String {
            toolDir.map { "in \($0)" } ?? "in the catalog's folders or PATH"
        }
    }

    /// The inputs file `build_inputs.rb` writes.
    struct Inputs: Decodable {
        struct Case: Decodable {
            let id: String
            let input: RuleCheckJobInput
        }

        let suite: String
        let cases: [Case]

        static func read(_ path: String) throws -> Inputs {
            let inputs = try JSONDecoder().decode(Inputs.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            guard !inputs.cases.isEmpty else { throw Refusal(reason: "it holds no case") }
            guard Set(inputs.cases.map(\.id)).count == inputs.cases.count else {
                throw Refusal(reason: "two cases share an id")
            }
            return inputs
        }
    }

    /// One case's line.
    struct Line: Encodable {
        let `case`: String
        var verdict: RuleCheckVerdict?
        var tokens = 0
        var seconds = 0.0
        var toolRuns = 0
        let toolVersion: String
        var notReached = false

        init(case id: String, toolVersion: String) {
            self.case = id
            self.toolVersion = toolVersion
        }

        var verdictWord: String { verdict?.result.rawValue ?? "none" }

        enum CodingKeys: String, CodingKey {
            case `case`, verdict, reason, tokens, seconds, model
            case toolRuns = "tool_runs"
            case toolVersion = "tool_version"
            case notReached = "not_reached"
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(self.case, forKey: .case)
            try container.encode(verdictWord, forKey: .verdict)
            if let reason = verdict?.reason {
                try container.encode(reason, forKey: .reason)
            } else {
                try container.encodeNil(forKey: .reason)
            }
            try container.encode(tokens, forKey: .tokens)
            try container.encode(seconds, forKey: .seconds)
            try container.encode(toolRuns, forKey: .toolRuns)
            try container.encode(toolVersion, forKey: .toolVersion)
            try container.encode(EvalRun.defaultModel, forKey: .model)
            if notReached { try container.encode(true, forKey: .notReached) }
        }
    }

    /// The output file, one line appended per case as it ends.
    struct Lines {
        let path: String

        func append(_ line: Line) throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: encoder.encode(line) + Data("\n".utf8))
        }
    }

    /// The driver, counting its tool runs and their tokens; once the ceiling
    /// is reached it starts no tool.
    final class CountingDriver: ToolDriver, @unchecked Sendable {
        private let driver: any ToolDriver
        private let ceiling: Int
        private let lock = NSLock()
        private var made = 0
        private var tokensByRun: [Int] = []

        init(driver: any ToolDriver, ceiling: Int) {
            self.driver = driver
            self.ceiling = ceiling
        }

        var runs: Int { lock.withLock { made } }

        /// The tokens of the runs after the first `run` of them.
        func tokens(since run: Int) -> Int { lock.withLock { tokensByRun.dropFirst(run).reduce(0, +) } }

        func execute(_ request: ToolRunRequest) async throws -> ToolRun {
            let allowed = lock.withLock { () -> Bool in
                guard made < ceiling else { return false }
                made += 1
                tokensByRun.append(0)
                return true
            }
            guard allowed else { return .failed(.couldNotStart("the eval's ceiling of tool runs is reached"), nil) }
            let run = try await driver.execute(request)
            if case .answered(let answer) = run {
                lock.withLock { tokensByRun[tokensByRun.count - 1] = answer.tokens }
            }
            return run
        }
    }

    /// The API of a run with no server: `CheckJob` calls none of it.
    struct NoServer: AgentAPI {
        struct NotCalled: Error {}

        func next(wait: Int?) async throws -> NextItem { throw NotCalled() }
        func command(key: IdempotencyKey) async throws -> PlainOutcome { throw NotCalled() }
        func claimNextTask(key: IdempotencyKey) async throws -> CommandOutcome<TaskClaim> { throw NotCalled() }
        func taskBriefing(taskID: UUID) async throws -> BriefingResponse { throw NotCalled() }
        func acknowledgeTaskBriefing(taskID: UUID, briefingHash: String, key: IdempotencyKey) async throws
            -> PlainOutcome { throw NotCalled() }
        func heartbeatTask(taskID: UUID, key: IdempotencyKey) async throws -> CommandOutcome<HeartbeatResult> {
            throw NotCalled()
        }
        func startCriterion(taskID: UUID, criterionID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
            throw NotCalled()
        }
        func passCriterion(taskID: UUID, criterionID: UUID, evidence: EvidenceInput, key: IdempotencyKey)
            async throws -> PlainOutcome { throw NotCalled() }
        func submitTask(taskID: UUID, _ request: SubmitTaskRequest, key: IdempotencyKey) async throws
            -> PlainOutcome { throw NotCalled() }
        func releaseTask(taskID: UUID, reason: ReleaseReason, key: IdempotencyKey) async throws -> PlainOutcome {
            throw NotCalled()
        }
        func claimNextReview(key: IdempotencyKey) async throws -> CommandOutcome<ReviewClaim> { throw NotCalled() }
        func reviewBriefing(reviewID: UUID) async throws -> BriefingResponse { throw NotCalled() }
        func acknowledgeReviewBriefing(reviewID: UUID, briefingHash: String, key: IdempotencyKey) async throws
            -> PlainOutcome { throw NotCalled() }
        func heartbeatReview(reviewID: UUID, key: IdempotencyKey) async throws -> CommandOutcome<HeartbeatResult> {
            throw NotCalled()
        }
        func releaseReview(reviewID: UUID, key: IdempotencyKey) async throws -> PlainOutcome { throw NotCalled() }
        func giveVerdict(reviewID: UUID, _ request: GiveVerdictRequest, key: IdempotencyKey) async throws
            -> PlainOutcome { throw NotCalled() }
        func claimNextJob(key: IdempotencyKey) async throws -> CommandOutcome<JobClaim> { throw NotCalled() }
        func submitJobResult(jobID: UUID, _ request: JobResultRequest, key: IdempotencyKey) async throws
            -> PlainOutcome { throw NotCalled() }
    }
}
