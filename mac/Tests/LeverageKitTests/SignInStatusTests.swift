import Foundation
import LeverageTestSupport
import Testing

@testable import LeverageKit

/// `SignInStatus`: "is this account signed in", from the catalog's status
/// command (plan PV-3, HD-5, §2.2). A status command prints the account's
/// email, organisation and plan, so only one of four answers may leave the
/// function, and nothing of the output may reach the answer or a log line.
/// These tests run the stand-in tools, whose status replies print a made-up
/// email and organisation, and small tools of their own for the replies the
/// stand-ins print neither in.
@Suite("SignInStatus")
struct SignInStatusTests {
    /// A log that keeps every line it is given, after redaction.
    final class CapturedLog: @unchecked Sendable {
        private let lock = NSLock()
        private var kept: [String] = []

        var lines: [String] { lock.withLock { kept } }

        func log() -> Log {
            Log(component: "test") { [self] line in lock.withLock { kept.append(line) } }
        }
    }

    private let secrets = [StandIns.statusEmail, StandIns.statusOrganisation]

    /// The answer, its every description and every log line are free of the
    /// made-up email and organisation.
    private func expectNothingLeaks(_ answer: SignInAnswer, _ log: CapturedLog) {
        let said = [String(describing: answer), String(reflecting: answer), answer.rawValue] + log.lines
        for secret in secrets {
            for text in said {
                #expect(!text.contains(secret), "\"\(text)\" holds what the status command printed")
            }
        }
    }

    private func check(
        _ entry: ProviderEntry, tool: URL, environment: [String: String], log: CapturedLog,
        timeLimit: Duration = Patience.scaled(.seconds(20))
    ) async -> SignInAnswer {
        await SignInStatus.check(
            entry, toolPath: tool.path, environment: environment, timeLimit: timeLimit, log: log.log())
    }

    @Test("signed out, then signed in, by each stand-in's status command", arguments: ["claude", "codex", "grok"])
    func standIns(provider: String) async throws {
        let folder = try TemporaryFolder(prefix: "sign-in-status")
        let tools = try StandIns.copy(into: folder.url)
        let entry = try #require(ProviderCatalog.entry(for: provider))
        let account = entry.accountFolderVariable.value == nil ? nil : try folder.folder("account")
        let environment = ProviderCatalog.toolEnvironment(
            for: entry, from: ProcessInfo.processInfo.environment, toolFolder: tools.bin.path,
            accountFolder: account?.path, supportFolder: folder.path("support").path, toolDir: tools.bin.path)
        let tool = tools.tool(entry.toolName)

        let outLog = CapturedLog()
        let out = await check(entry, tool: tool, environment: environment, log: outLog)
        #expect(out == .signedOut)
        expectNothingLeaks(out, outLog)

        try tools.signIn(entry.toolName, accountFolder: account)
        let inLog = CapturedLog()
        let signedIn = await check(entry, tool: tool, environment: environment, log: inLog)
        #expect(signedIn == .signedIn)
        expectNothingLeaks(signedIn, inLog)
        // The log says what was found, so a line that also held the output
        // would be seen here.
        #expect(inLog.lines.count == 1)
        #expect(inLog.lines.first?.contains("\(provider): signed in") == true)

        // The stand-in's signed-in reply did print both, so the test above
        // could have failed.
        let calls = try tools.calls().filter { $0.tool == entry.toolName }
        #expect(calls.count == 2)
    }

    @Test("a provider with no status command says so, and nothing is run")
    func noStatusCommand() async throws {
        let folder = try TemporaryFolder(prefix: "sign-in-status")
        let tools = try StandIns.copy(into: folder.url)
        let entry = try #require(ProviderCatalog.entry(for: "gemini"))
        try tools.signIn("agy")
        let log = CapturedLog()

        let answer = await check(entry, tool: tools.tool("agy"), environment: [:], log: log)

        #expect(answer == .noStatusCommand)
        #expect(try tools.calls().isEmpty)
        expectNothingLeaks(answer, log)
    }

    /// A status tool of the test's own: `script` is its body.
    private func ownTool(_ folder: TemporaryFolder, _ script: String) throws -> URL {
        let tool = folder.path("status-tool")
        try Data("#!/bin/sh\n\(script)\n".utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        return tool
    }

    private func entry(_ reading: StatusCheck.Reading, from id: String = "claude") throws -> ProviderEntry {
        let base = try #require(ProviderCatalog.entry(for: id))
        return ProviderEntry(
            id: base.id, displayName: base.displayName, toolDisplayName: base.toolDisplayName,
            toolName: base.toolName, accountFolderVariable: base.accountFolderVariable, version: base.version,
            status: Evidenced(StatusCheck(arguments: ["status"], reading: reading), .unverified),
            signIn: base.signIn, installer: base.installer, environment: base.environment,
            defaultModel: base.defaultModel)
    }

    private var email: String { StandIns.statusEmail }
    private var organisation: String { StandIns.statusOrganisation }

    @Test("a signed-out reply that also prints the email and organisation gives neither back")
    func signedOutWithIdentity() async throws {
        let folder = try TemporaryFolder(prefix: "sign-in-status")
        let replies: [(StatusCheck.Reading, String)] = [
            (.jsonField("loggedIn"),
             #"echo '{"loggedIn": false, "email": "\#(email)", "orgName": "\#(organisation)"}'; exit 1"#),
            (.exitCode, #"echo "Not logged in (\#(email), \#(organisation))" >&2; exit 1"#),
            (.signedOutText("You are not authenticated."),
             #"echo "You are not authenticated. Last account: \#(email) (\#(organisation))""#),
        ]
        for (reading, script) in replies {
            let log = CapturedLog()
            let answer = await check(
                try entry(reading), tool: try ownTool(folder, script), environment: [:], log: log)
            #expect(answer == .signedOut, "\(reading)")
            expectNothingLeaks(answer, log)
        }
    }

    // Review: a sign-out is reported only on what the tool itself says;
    // a status command that fails, crashes or prints something else said
    // nothing either way, so it cannot tell (and the runner then goes on as
    // milestone 2 does instead of reporting a sign-out).

    @Test("a signed-in field that is not a Boolean, or output that is not JSON, cannot tell")
    func jsonFieldMustBeABoolean() async throws {
        let folder = try TemporaryFolder(prefix: "sign-in-status")
        let scripts = [
            #"echo '{"loggedIn": "true", "email": "\#(email)"}'"#, #"echo '{"loggedIn": 1}'"#,
            #"echo '{"loggedIn": null}'"#, #"echo '{"other": false}'"#, "echo 'not json at all'; exit 1",
            "echo 'Segmentation fault' >&2; exit 139",
        ]
        for script in scripts {
            let log = CapturedLog()
            let answer = await check(
                try entry(.jsonField("loggedIn")), tool: try ownTool(folder, script), environment: [:], log: log)
            #expect(answer == .couldNotTell, "\(script)")
            expectNothingLeaks(answer, log)
        }
        let log = CapturedLog()
        let out = await check(
            try entry(.jsonField("loggedIn")), tool: try ownTool(folder, #"echo '{"loggedIn": false}'; exit 1"#),
            environment: [:], log: log)
        #expect(out == .signedOut, "the Boolean false is a sign-out")
    }

    @Test("signed-in text with a non-zero exit cannot tell; the signed-out text is a sign-out whatever the exit")
    func signedOutTextNeedsTheText() async throws {
        let folder = try TemporaryFolder(prefix: "sign-in-status")
        let log = CapturedLog()
        let reading = StatusCheck.Reading.signedOutText("You are not authenticated.")
        let answer = await check(
            try entry(reading), tool: try ownTool(folder, #"echo "Signed in as \#(email)"; exit 3"#), environment: [:],
            log: log)
        #expect(answer == .couldNotTell)
        expectNothingLeaks(answer, log)
        let out = await check(
            try entry(reading), tool: try ownTool(folder, #"echo "You are not authenticated." >&2; exit 2"#),
            environment: [:], log: CapturedLog())
        #expect(out == .signedOut)
    }

    @Test("each provider's own status command that fails without its signed-out reply cannot tell",
          arguments: ["claude", "codex", "grok"])
    func failedStatusCannotTell(provider: String) async throws {
        let folder = try TemporaryFolder(prefix: "sign-in-status")
        let base = try #require(ProviderCatalog.entry(for: provider))
        let entry = try entry(base.status.value.reading, from: provider)
        for script in ["echo 'error: could not reach the server' >&2; exit 1", "kill -9 $$"] {
            let log = CapturedLog()
            let answer = await check(entry, tool: try ownTool(folder, script), environment: [:], log: log)
            #expect(answer == .couldNotTell, "\(provider): \(script)")
        }
    }

    @Test("Codex's status command is a sign-out only with its recorded \"Not logged in\"")
    func codexNeedsItsText() async throws {
        let folder = try TemporaryFolder(prefix: "sign-in-status")
        let base = try #require(ProviderCatalog.entry(for: "codex"))
        let entry = try entry(base.status.value.reading, from: "codex")
        let out = await check(
            entry, tool: try ownTool(folder, #"echo "Not logged in" >&2; exit 1"#), environment: [:], log: CapturedLog())
        #expect(out == .signedOut)
        let signedIn = await check(
            entry, tool: try ownTool(folder, #"echo "Logged in using ChatGPT" >&2"#), environment: [:],
            log: CapturedLog())
        #expect(signedIn == .signedIn)
    }

    @Test("a status command that passes its time limit cannot tell, and its output is not kept")
    func timeLimit() async throws {
        let folder = try TemporaryFolder(prefix: "sign-in-status")
        let log = CapturedLog()
        // The short limit is what this test asserts, so it is not scaled.
        let answer = await check(
            try entry(.exitCode),
            tool: try ownTool(folder, #"echo "Signed in as \#(email) (\#(organisation))"; exec /bin/sleep 30"#),
            environment: [:], log: log, timeLimit: .milliseconds(300))
        #expect(answer == .couldNotTell)
        expectNothingLeaks(answer, log)
    }

    @Test("a tool that cannot be started cannot tell")
    func cannotStart() async throws {
        let folder = try TemporaryFolder(prefix: "sign-in-status")
        let log = CapturedLog()
        let answer = await check(
            try entry(.exitCode), tool: folder.path("missing-tool"), environment: [:], log: log)
        #expect(answer == .couldNotTell)
    }

    @Test("the four answers, and nothing else, can leave the function")
    func fourAnswers() {
        #expect(SignInAnswer.allCases == [.signedIn, .signedOut, .noStatusCommand, .couldNotTell])
    }
}
