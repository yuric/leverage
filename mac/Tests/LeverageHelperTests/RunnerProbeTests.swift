import Foundation
import LeverageKit
import LeverageTestSupport
import Testing

@testable import LeverageHelper

/// The test prompt of Add credential runs `LeverageRunner probe` (plan
/// §2.2), so the four drivers stay in the runner. The runner here is a
/// script the test writes, which records how it was started.
@Suite("Runner probe", .timeLimit(.minutes(1)))
struct RunnerProbeTests {
    private func probeScript(_ rig: HelperRig, exitCode: Int) throws -> URL {
        let script = rig.folder.path("probe-runner.sh")
        let record = rig.folder.path("probe-record.txt")
        try Data("""
            #!/bin/sh
            printf '%s\\n' "$@" > '\(record.path)'
            env >> '\(record.path)'
            exit \(exitCode)

            """.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    @Test("it runs the runner's probe with the provider, the tool and the folder, and no token")
    func runsProbe() async throws {
        let rig = try HelperRig()
        rig.settings.runnerPath = try probeScript(rig, exitCode: 0).path
        let folder = try rig.folders.createFresh(for: UUID())
        let entry = ProviderCatalog.entry(for: "claude")!
        let tool = LocatedTool(path: rig.tools.tool("claude").path, version: "1")

        let answered = await RunnerProbe(timings: fastTimings).answers(
            entry, tool: tool, accountFolder: folder, settings: rig.settings)

        #expect(answered)
        let record = try String(contentsOf: rig.folder.path("probe-record.txt"), encoding: .utf8)
        let lines = record.split(separator: "\n").map(String.init)
        #expect(lines.first == "probe")
        #expect(lines.contains("\(EnvironmentKeys.provider)=claude"))
        #expect(lines.contains("\(EnvironmentKeys.toolPath)=\(tool.path)"))
        #expect(lines.contains("\(EnvironmentKeys.settingsDir)=\(folder.path)"))
        #expect(!record.contains(EnvironmentKeys.seatToken))
        #expect(!record.contains(MadeUp.helperToken))
        #expect(!record.contains(EnvironmentKeys.devToolLogin))
    }

    @Test("a probe that exits 1 is no answer")
    func noAnswer() async throws {
        let rig = try HelperRig()
        rig.settings.runnerPath = try probeScript(rig, exitCode: 1).path
        let entry = ProviderCatalog.entry(for: "gemini")!

        let answered = await RunnerProbe(timings: fastTimings).answers(
            entry, tool: LocatedTool(path: rig.tools.tool("agy").path, version: "1"), accountFolder: nil,
            settings: rig.settings)

        #expect(!answered)
    }

    @Test("a missing runner is no answer")
    func missingRunner() async throws {
        let rig = try HelperRig()
        rig.settings.runnerPath = rig.folder.path("no-such-runner").path

        let answered = await RunnerProbe(timings: fastTimings).answers(
            ProviderCatalog.entry(for: "codex")!, tool: LocatedTool(path: rig.tools.tool("codex").path, version: "1"),
            accountFolder: nil, settings: rig.settings)

        #expect(!answered)
    }
}
