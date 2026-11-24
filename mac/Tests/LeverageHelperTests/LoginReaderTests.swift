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

@Suite("Login readers", .timeLimit(.minutes(Patience.minutes(1))))
struct LoginReaderTests {
    @Test("signed-out accounts stop after version and status", arguments: [Provider.claude, .codex])
    func signedOut(provider: Provider) async throws {
        let rig = try HelperRig()
        let credential = UUID()
        _ = try rig.folders.createFresh(for: credential)
        let (tool, version) = standIn(for: provider)
        try rig.tools.write(scenario: .init(usage: [.init(tool: tool, version: version)]))
        let readings = UsageReadTests.recordReadings(rig)

        let result = await usageRead(rig, readers: Self.capturedReader).run(loginRequest(credential, provider: provider))

        #expect(result.outcome == .finished)
        let reading = try #require(readings.value.first)
        #expect(reading.state == .signedOut)
        #expect(reading.figures.isEmpty)
        #expect(reading.resets == nil)
        let calls = try rig.tools.calls()
        #expect(calls.map(\.tool) == [tool, tool])
        #expect(calls.map(\.argv) == [["--version"], provider == .claude ? ["auth", "status"] : ["login", "status"]])
    }

    @Test("Refresh starts no tool for a login without a reader", arguments: [Provider.claude, .gemini, .grok])
    func noReader(provider: Provider) async throws {
        let rig = try HelperRig()
        let readings = UsageReadTests.recordReadings(rig)
        let result = await usageRead(rig).run(loginRequest(UUID(), provider: provider))

        #expect(result.outcome == .finished)
        let reading = try #require(readings.value.first)
        #expect(reading.state == .unavailable)
        #expect(try rig.tools.calls().isEmpty)
    }

    @Test("two uses of a provider run in distinct empty directories and use only their own account",
          arguments: [Provider.claude, .codex])
    func twoAccounts(provider: Provider) async throws {
        let rig = try HelperRig()
        let (tool, version) = standIn(for: provider)
        let ids = [UUID(), UUID()]
        let folders = try ids.map { try rig.folders.createFresh(for: $0) }
        for folder in folders {
            try rig.tools.signIn(tool, accountFolder: folder)
        }
        let replies = provider == .claude
            ? ["claude/usage-unrecognized-result.json", "claude/usage-unrecognized-result.json"]
            : ["codex/usage-both-windows.json", "codex/usage-one-window.json"]
        let scenarios = folders.indices.map { index in
            StandInScenario.UsageDirective(
                tool: tool, account: folders[index], reply: replies[index],
                settings: provider == .claude && index == 0 ? "claude/usage-settings-empty-list.json" : nil)
        }
        try rig.tools.write(scenario: .init(usage: [.init(tool: tool, version: version)] + scenarios))
        let readings = UsageReadTests.recordReadings(rig)
        let enteredDirectories = Locked<[String]>([])
        let read = usageRead(rig, readers: { provider in
            Self.capturedReader(provider).map { InspectWorkingFolder(reader: $0, entered: enteredDirectories) }
        })

        for id in ids {
            let result = await read.run(loginRequest(id, provider: provider))
            #expect(result.outcome == .finished)
        }

        let actual = readings.value
        #expect(actual.map(\.credentialID) == ids)
        try #require(actual.count == replies.count)
        for (reading, name) in zip(actual, replies) {
            let expected = try LoginReaderFixtureTests.Reply.load(StandIns.replies.appendingPathComponent(name)).meta.expect
            #expect(reading.state == expected.state)
            #expect(reading.figures == expected.figures)
            #expect(reading.resets == expected.resets)
        }
        if provider == .codex {
            #expect(actual[0].figures != actual[1].figures)
        } else {
            let configExists = folders.map {
                FileManager.default.fileExists(atPath: $0.appendingPathComponent(".claude.json").path)
            }
            #expect(configExists == [true, false])
        }

        let directories = enteredDirectories.value
        #expect(Set(directories).count == 2)
        let calls = try rig.tools.calls().filter { call in
            provider == .claude ? call.argv.contains("/usage") : call.argv == ["app-server"]
        }
        let accountVariable = provider == .claude ? "CLAUDE_CONFIG_DIR" : "CODEX_HOME"
        #expect(calls.map { $0.env[accountVariable] } == folders.map { Optional($0.path) })
        #expect(calls.map(\.cwd) == directories)
        if provider == .claude {
            let args = [
                "-p", "/usage", "--output-format", "json", "--no-session-persistence",
                "--permission-mode", "dontAsk", "--strict-mcp-config", "--setting-sources", "user", "--tools", "",
            ]
            #expect(calls.map(\.argv) == [args, args])
        }
        #expect(directories.allSatisfy { !FileManager.default.fileExists(atPath: $0) })
        let reads = rig.support.appendingPathComponent("reads", isDirectory: true)
        #expect(try FileManager.default.contentsOfDirectory(atPath: reads.path).isEmpty)
    }

    private func usageRead(
        _ rig: HelperRig, readers: @escaping UsageReaders.Lookup = UsageReaders.reader(for:)
    ) -> UsageRead {
        var timings = fastTimings
        timings.readLimit = Patience.scaled(.seconds(45))
        return UsageRead(
            api: rig.api, settings: rig.settings, timings: timings, http: ProviderHTTP(), vault: MemoryTokenVault(),
            log: quietLog, readers: readers,
            testedVersions: { provider in
                switch provider {
                case .claude: ["2.1.325"]
                case .codex: ["0.169.0"]
                default: []
                }
            })
    }

    private static func capturedReader(_ provider: Provider) -> (any UsageReader)? {
        if provider == .claude { return ClaudeUsageReader() }
        return UsageReaders.reader(for: provider)
    }

    private func standIn(for provider: Provider) -> (String, String) {
        provider == .claude ? ("claude", "2.1.325 (Claude Code)") : ("codex", "codex-cli 0.169.0")
    }

    private struct InspectWorkingFolder: UsageReader {
        let reader: any UsageReader
        let entered: Locked<[String]>

        func read(_ account: ReaderAccount) async throws -> UsageReading {
            let files = FileManager.default
            #expect(try files.contentsOfDirectory(atPath: account.workingDirectory.path).isEmpty)
            let canonicalPath = try #require(realpath(account.workingDirectory.path, nil))
            defer { free(canonicalPath) }
            entered.update { $0.append(String(cString: canonicalPath)) }
            let reading = try await reader.read(account)
            try Data().write(to: account.workingDirectory.appendingPathComponent("reader-work"))
            return reading
        }
    }
}
