import Foundation
import LeverageTestSupport
import Testing

@testable import LeverageKit

/// The detectors against every reply file under `mac/Tests/StandIns/replies/`
/// (plan HD-7, HD-8): each file's `meta.expect` is the outcome its
/// provider's detector must give, or, for a status command's reply, the
/// answer `SignInStatus` must read from it. The same files are what the
/// stand-ins play (HD-11), which the last tests here run.
@Suite("Detectors against the reply files", .timeLimit(.minutes(Patience.minutes(2))))
struct DetectorFixtureTests {
    /// The reset time every limit reply that states one is filled in with,
    /// and the moment the run ended, an hour before it.
    static let resetAt = Date(timeIntervalSince1970: 1_795_000_000)
    static let endedAt = resetAt.addingTimeInterval(-3600)

    @Test("every reply file gives the outcome its meta expects", arguments: ReplyFile.paths)
    func replyFile(path: String) throws {
        let reply = try ReplyFile(path: path)
        let record = reply.record(resetAt: Self.resetAt)
        switch reply.meta.kind {
        case "run":
            let detector = try #require(Detectors.detector(for: reply.provider))
            let outcome = detector.outcome(of: record, at: Self.endedAt)
            #expect(outcome == (try reply.expectedOutcome(resetAt: Self.resetAt)), "\(path)")
        case "status":
            let entry = try #require(ProviderCatalog.entry(for: reply.provider.rawValue))
            let result = SubprocessResult(
                termination: record.termination, standardOutput: record.standardOutput,
                standardError: record.standardError, endedBy: nil, outputTruncated: false)
            let answer = SignInStatus.answer(entry.status.value.reading, result)
            #expect(reply.meta.expect == "signed_out", "\(path): a status reply is recorded signed out")
            #expect(answer == (reply.meta.expect == "signed_in" ? .signedIn : .signedOut), "\(path)")
        default:
            Issue.record("\(path): unknown kind \(reply.meta.kind)")
        }
    }

    @Test("each provider has a limit, a short rate limit, a sign-out and a plain failure to test against",
          arguments: Provider.allCases.filter { $0.kind == .login })
    func coverage(provider: Provider) throws {
        let runs = try ReplyFile.all().filter { $0.provider == provider && $0.meta.kind == "run" }
        let expected = Set(runs.map(\.meta.expect))
        #expect(expected == ["limit", "rate_limited", "signed_out", "failed"], "\(provider)")
    }

    @Test("a detector's rules name every run reply of its provider, with the file's basis",
          arguments: Provider.allCases.filter { $0.kind == .login })
    func rulesNameTheirFiles(provider: Provider) throws {
        let detector = try #require(Detectors.detector(for: provider))
        #expect(detector.provider == provider)
        let runs = try ReplyFile.all().filter { $0.provider == provider && $0.meta.kind == "run" }
        let byName = Dictionary(uniqueKeysWithValues: runs.map { ($0.fileName, $0) })
        #expect(Set(detector.rules.map(\.replyFile)) == Set(byName.keys), "\(provider)")
        #expect(detector.rules.count == byName.count, "\(provider): one rule per reply file")
        for rule in detector.rules {
            let file = try #require(byName[rule.replyFile], "\(provider): \(rule.replyFile)")
            #expect(rule.basis.rawValue == file.meta.basis, "\(provider): \(rule.replyFile)")
            #expect(!rule.name.isEmpty)
        }
    }

    @Test("a detector was tested against the tool versions of its recorded replies",
          arguments: Provider.allCases.filter { $0.kind == .login })
    func testedVersions(provider: Provider) throws {
        let detector = try #require(Detectors.detector(for: provider))
        let recorded = try ReplyFile.all().filter {
            $0.provider == provider && $0.meta.kind == "run" && $0.meta.basis == "recorded_no_login"
        }
        #expect(detector.testedToolVersions == Array(Set(recorded.map(\.meta.toolVersion))).sorted(), "\(provider)")
    }

    @Test("a reply that does not end the account is never read as stopping it")
    func onlyLimitsAndSignOutsStop() throws {
        for reply in try ReplyFile.all() where reply.meta.kind == "run" {
            let detector = try #require(Detectors.detector(for: reply.provider))
            let outcome = detector.outcome(of: reply.record(resetAt: Self.resetAt), at: Self.endedAt)
            #expect(outcome.stopsTheAccount == ["limit", "signed_out"].contains(reply.meta.expect), "\(reply.path)")
        }
    }

    @Test("an empty run, and a run that exited 0 with an empty answer, are plain failures",
          arguments: Provider.allCases.filter { $0.kind == .login })
    func emptyRuns(provider: Provider) throws {
        let detector = try #require(Detectors.detector(for: provider))
        for status: Int32 in [0, 1, 2] {
            let record = ToolRunRecord(termination: .exited(status), standardOutput: Data(), standardError: Data())
            #expect(detector.outcome(of: record, at: Self.endedAt) == .failed, "\(provider) \(status)")
        }
        let killed = ToolRunRecord(
            termination: .signaled(15), standardOutput: Data(), standardError: Data(), endedBy: .timeLimit)
        #expect(detector.outcome(of: killed, at: Self.endedAt) == .failed, "\(provider)")
    }

    // MARK: Guards no reply file reaches

    struct Inline: Sendable, CustomTestStringConvertible {
        let provider: Provider
        let why: String
        let exit: Int32
        let stdout: String
        let stderr: String
        var endedBy: SubprocessEnd? = nil
        var testDescription: String { "\(provider.rawValue): \(why)" }
    }

    static let inline: [Inline] = [
        Inline(
            provider: .claude, why: "an error that names a window but no limit",
            exit: 1, stdout: #"{"type":"result","is_error":true,"result":"API Error: 500 while saving the weekly report"}"#,
            stderr: ""),
        Inline(
            provider: .claude, why: "a result that is no error, with a 429 on standard error",
            exit: 0, stdout: #"{"type":"result","is_error":false,"result":"done"}"#,
            stderr: "retrying after 429 Too Many Requests"),
        Inline(
            provider: .claude, why: "a limit reply cut off by leverage's time limit",
            exit: 1, stdout: #"{"type":"result","is_error":true,"result":"You have reached your weekly limit."}"#,
            stderr: "", endedBy: .timeLimit),
        Inline(
            provider: .codex, why: "reconnect errors in a run that then succeeded",
            exit: 0,
            stdout: #"{"type":"error","message":"Reconnecting... 1/5 (unexpected status 429 Too Many Requests)"}"#
                + "\n" + #"{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}"#,
            stderr: ""),
        Inline(
            provider: .gemini, why: "a successful reply with a 429 on standard error",
            exit: 0, stdout: #"{"status":"SUCCESS","response":"done","error":"429 Too Many Requests"}"#,
            stderr: "429 Too Many Requests"),
        Inline(
            provider: .grok, why: "a sign-out reply cut off by a stop",
            exit: 1, stdout: "You are not authenticated.\n", stderr: "", endedBy: .stop),
        // Review: Grok's standard output is the agent's answer; text in it
        // never reads as a limit or a sign-out, whatever the exit status.
        Inline(
            provider: .grok, why: "an answer that says it is not authenticated and names a limit, on standard output",
            exit: 1,
            stdout: "You are not authenticated. Your weekly limit was reached; it resets at 2027-01-01T00:00:00Z.\n",
            stderr: ""),
        Inline(
            provider: .codex, why: "an output limit, which is no usage limit",
            exit: 1,
            stdout: #"{"type":"turn.failed","error":{"message":"the output limit of the model was reached"}}"#,
            stderr: ""),
    ]

    @Test("a reply a guard keeps from being read is a plain failure", arguments: inline)
    func guards(_ case_: Inline) throws {
        let detector = try #require(Detectors.detector(for: case_.provider))
        let record = ToolRunRecord(
            termination: .exited(case_.exit), standardOutput: Data(case_.stdout.utf8),
            standardError: Data(case_.stderr.utf8), endedBy: case_.endedBy)
        #expect(detector.outcome(of: record, at: Self.endedAt) == .failed)
    }

    // Review: a run killed by a signal leverage did not send (a crash, an
    // outside kill) ended before it finished its reply: never read.
    @Test("a run killed by a signal is never read, whatever it printed", arguments: try ReplyFile.all().filter {
        $0.meta.kind == "run" && ["limit", "signed_out"].contains($0.meta.expect)
    }.map(\.path))
    func signaled(path: String) throws {
        let reply = try ReplyFile(path: path)
        let record = reply.record(resetAt: Self.resetAt)
        let detector = try #require(Detectors.detector(for: reply.provider))
        for signal: Int32 in [9, 15] {
            let killed = ToolRunRecord(
                termination: .signaled(signal), standardOutput: record.standardOutput,
                standardError: record.standardError)
            #expect(detector.outcome(of: killed, at: Self.endedAt) == .failed, "\(path) \(signal)")
        }
    }

    // Review: a stated time is a reset time only after a reset word, never a
    // log line's own leading timestamp.
    @Test("a time is a reset time only after resets, reset at or try again at, on the same line")
    func resetWords() {
        let base = Date(timeIntervalSince1970: 1_795_000_000)
        #expect(ReplyReading.statedTime(in: "2026-11-20T01:23:00Z ERROR you hit your weekly limit") == nil)
        #expect(ReplyReading.statedTime(
            in: "2026-11-20T01:23:00Z ERROR weekly limit; it resets at 2026-11-18T11:06:40Z") == base)
        #expect(ReplyReading.statedTime(in: "Limit reached. Try again at 2026-11-18T11:06:40Z.") == base)
        #expect(ReplyReading.statedTime(in: "reset at: 2026-11-18T11:06:40Z") == base)
        #expect(ReplyReading.statedTime(in: "it resets soon\n2026-11-20T01:23:00Z next line") == nil)
        // Second review: a bare "reset" or a "try again" with no "at" is no
        // reset word.
        #expect(ReplyReading.statedTime(in: "weekly limit; password reset 2026-11-18T11:06:40Z") == nil)
        #expect(ReplyReading.statedTime(in: "weekly limit, try again later (logged 2026-11-18T11:06:40Z)") == nil)
        #expect(ReplyReading.outcome(
            errorText: "2026-11-20T01:23:00Z weekly limit reached", signedOutPhrases: [])
            == .limit(window: .weekly, resetAt: nil))
    }

    @Test("a time the reply states in another form is read; one it does not state is not estimated")
    func statedTimes() {
        let base = Date(timeIntervalSince1970: 1_795_000_000)
        #expect(ReplyReading.statedTime(in: "resets at 2026-11-18T11:06:40Z.") == base)
        #expect(ReplyReading.statedTime(in: "resets at 2026-11-18T11:06:40.000Z") == base)
        #expect(ReplyReading.statedTime(in: "resets at 2026-11-18T12:06:40+01:00") == base)
        #expect(ReplyReading.statedTime(in: "resets in 2 hours") == nil)
        #expect(ReplyReading.time(fromSeconds: 1_795_000_000) == base)
        #expect(ReplyReading.time(fromSeconds: "soon") == nil)
    }

    // MARK: The stand-ins play the same files

    /// One tool's work prompt as its driver runs it, closely enough for the
    /// stand-in: the prompt and the flags the stand-in reads.
    static func workPrompt(_ tool: String, folder: URL) -> [String] {
        let prompt = "Work on criterion 1. End with LEVERAGE-EVIDENCE: <where> or LEVERAGE-CANNOT: <why>."
        switch tool {
        case "claude": return ["-p", prompt, "--output-format", "json"]
        case "codex": return ["exec", prompt, "--json", "-C", folder.path]
        case "agy": return ["-p", prompt, "--output-format", "json"]
        default: return ["-p", prompt, "--cwd", folder.path]
        }
    }

    struct Played: Sendable, CustomTestStringConvertible {
        let provider: Provider
        let reply: String
        let expect: RunOutcome
        var testDescription: String { "\(provider.rawValue) plays \(reply)" }
    }

    static let played: [Played] = [
        Played(provider: .claude, reply: "claude/run-limit-five-hour.json", expect: .limit(window: .fiveHour, resetAt: nil)),
        Played(provider: .codex, reply: "codex/run-limit-five-hour.json", expect: .limit(window: .fiveHour, resetAt: nil)),
        Played(provider: .gemini, reply: "gemini/run-limit-per-model.json", expect: .limit(window: .perModel, resetAt: nil)),
        Played(provider: .grok, reply: "grok/run-limit-spend.json", expect: .limit(window: .spend, resetAt: nil)),
        Played(provider: .codex, reply: "codex/run-rate-limited.json", expect: .rateLimited),
    ]

    @Test("a reply a stand-in plays by a directive is what the detector reads, with the reset it was given",
          arguments: played)
    func standInPlays(_ case_: Played) async throws {
        let folder = try TemporaryFolder(prefix: "detector-standin")
        let tools = try StandIns.copy(into: folder.url)
        let entry = try #require(ProviderCatalog.entry(for: case_.provider.rawValue))
        let account = entry.accountFolderVariable.value == nil ? nil : try folder.folder("account")
        try tools.signIn(entry.toolName, accountFolder: account)
        let resetIn = 300
        try tools.write(scenario: StandInScenario(directives: [
            .reply(case_.reply, tool: entry.toolName, account: account, onPrompt: 1, resetInSeconds: resetIn)
        ]))
        let work = try folder.folder("work")
        let environment = ProviderCatalog.toolEnvironment(
            for: entry, from: ProcessInfo.processInfo.environment, toolFolder: tools.bin.path,
            accountFolder: account?.path, supportFolder: folder.path("support").path, toolDir: tools.bin.path)

        let started = Date()
        let result = try await Subprocess.run(SubprocessRequest(
            executable: tools.tool(entry.toolName).path, arguments: Self.workPrompt(entry.toolName, folder: work),
            environment: environment, workingDirectory: work.path, timeLimit: Patience.scaled(.seconds(30)),
            gracePeriod: .seconds(2)))
        let ended = Date()
        let detector = try #require(Detectors.detector(for: case_.provider))
        let outcome = detector.outcome(of: ToolRunRecord(result), at: ended)

        switch (outcome, case_.expect) {
        case (.limit(let window, let resetAt), .limit(let expectedWindow, _)):
            #expect(window == expectedWindow)
            // The stand-in states the reset to the second.
            let reset = try #require(resetAt, "the reset time the stand-in filled in")
            #expect(reset >= started.addingTimeInterval(Double(resetIn) - 1))
            #expect(reset <= ended.addingTimeInterval(Double(resetIn) + 1))
        default:
            #expect(outcome == case_.expect)
        }

        // The next work prompt is answered: the reply was given once.
        let again = try await Subprocess.run(SubprocessRequest(
            executable: tools.tool(entry.toolName).path, arguments: Self.workPrompt(entry.toolName, folder: work),
            environment: environment, workingDirectory: work.path, timeLimit: Patience.scaled(.seconds(30)),
            gracePeriod: .seconds(2)))
        #expect(again.succeeded)
    }

    @Test("a sign-out directive gives the recorded signed-out reply, which the detector reads as a sign-out",
          arguments: ["claude", "codex"])
    func standInSignsOut(tool: String) async throws {
        let folder = try TemporaryFolder(prefix: "detector-standin")
        let tools = try StandIns.copy(into: folder.url)
        let entry = try #require(ProviderCatalog.entry(for: tool))
        let account = try folder.folder("account")
        try tools.signIn(tool, accountFolder: account)
        try tools.write(scenario: StandInScenario(directives: [.signOut(tool: tool, account: account, beforePrompt: 1)]))
        let work = try folder.folder("work")
        let environment = ProviderCatalog.toolEnvironment(
            for: entry, from: ProcessInfo.processInfo.environment, toolFolder: tools.bin.path,
            accountFolder: account.path, supportFolder: folder.path("support").path, toolDir: tools.bin.path)
        let result = try await Subprocess.run(SubprocessRequest(
            executable: tools.tool(tool).path, arguments: Self.workPrompt(tool, folder: work),
            environment: environment, workingDirectory: work.path, timeLimit: Patience.scaled(.seconds(30)),
            gracePeriod: .seconds(2)))
        let provider = try #require(Provider(rawValue: tool))
        let detector = try #require(Detectors.detector(for: provider))
        #expect(detector.outcome(of: ToolRunRecord(result), at: Date()) == .signedOut)
        #expect(!tools.isSignedIn(tool, accountFolder: account))
    }
}

/// One reply file, read as the detector tests need it.
struct ReplyFile: Sendable {
    struct Meta: Decodable, Sendable {
        let provider: String
        let toolVersion: String
        let basis: String
        let kind: String
        let expect: String
        let expectWindow: String?
        let expectReset: String?
    }

    struct Contents: Decodable {
        let meta: Meta
        let exitStatus: Int32
        let stdout: String
        let stderr: String
    }

    /// Relative to the replies folder, such as `claude/run-signed-out.json`.
    let path: String
    let provider: Provider
    let meta: Meta
    let exitStatus: Int32
    let stdout: String
    let stderr: String

    var fileName: String { (path as NSString).lastPathComponent }

    /// Every run and status reply's path, sorted. Usage replies have their
    /// own shape and are exercised by the helper's reader fixture tests.
    static let paths: [String] = {
        let root = StandIns.replies
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix("usage-") } ?? []
        return files.map { String($0.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1)) }
            .sorted()
    }()

    static func all() throws -> [ReplyFile] {
        let files = try paths.map(ReplyFile.init(path:))
        if files.isEmpty { throw ReplyFileError("no reply file under \(StandIns.replies.path)") }
        return files
    }

    init(path: String) throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let contents = try decoder.decode(
            Contents.self, from: Data(contentsOf: StandIns.replies.appendingPathComponent(path)))
        guard let provider = Provider(rawValue: contents.meta.provider),
            path.hasPrefix("\(provider.rawValue)/")
        else { throw ReplyFileError("\(path): provider \(contents.meta.provider) is not its folder") }
        self.path = path
        self.provider = provider
        meta = contents.meta
        exitStatus = contents.exitStatus
        stdout = contents.stdout
        stderr = contents.stderr
    }

    /// The run as a detector is given it, with the reset time filled in as
    /// the stand-in fills it in.
    func record(resetAt: Date) -> ToolRunRecord {
        func filled(_ text: String) -> Data {
            let iso = ISO8601DateFormatter().string(from: resetAt)
            return Data(text
                .replacingOccurrences(of: "@RESET_AT_ISO@", with: iso)
                .replacingOccurrences(of: "\"@RESET_AT_EPOCH@\"", with: String(Int(resetAt.timeIntervalSince1970)))
                .utf8)
        }
        return ToolRunRecord(termination: .exited(exitStatus), standardOutput: filled(stdout), standardError: filled(stderr))
    }

    func expectedOutcome(resetAt: Date) throws -> RunOutcome {
        switch meta.expect {
        case "limit":
            guard let name = meta.expectWindow, let window = LimitWindow(rawValue: name) else {
                throw ReplyFileError("\(path): a limit names no window")
            }
            switch meta.expectReset {
            case "stated": return .limit(window: window, resetAt: resetAt)
            case "none": return .limit(window: window, resetAt: nil)
            default: throw ReplyFileError("\(path): expect_reset must be stated or none")
            }
        case "rate_limited": return .rateLimited
        case "signed_out": return .signedOut
        case "failed": return .failed
        default: throw ReplyFileError("\(path): unknown expectation \(meta.expect)")
        }
    }
}

struct ReplyFileError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
