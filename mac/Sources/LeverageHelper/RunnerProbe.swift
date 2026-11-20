import Foundation
import LeverageKit

/// The answering check of a login: one short test prompt gets an answer
/// (L602). Also Gemini's sign-in check, which has no status command (PV-3).
protocol TestPrompting: Sendable {
    func answers(_ entry: ProviderEntry, tool: LocatedTool, accountFolder: URL?, settings: HelperSettings) async
        -> Bool
}

/// The runner's environment (CL-10, §2.4): the system variables a tool
/// needs, which the runner passes on through `ProviderCatalog.toolEnvironment`,
/// and the run's own inputs. Never the helper's token, never the developer
/// switch of PV-6; the seat token only when a run is started with one.
enum RunnerEnvironment {
    /// What the runner takes from the helper's environment.
    static let passed = [
        EnvironmentKeys.home, EnvironmentKeys.tmpdir, EnvironmentKeys.lang, EnvironmentKeys.user,
        EnvironmentKeys.toolTimeoutSeconds,
    ]

    static func build(
        settings: HelperSettings, provider: String, tool: LocatedTool, accountFolder: URL?,
        setting extra: [String: String] = [:]
    ) -> [String: String] {
        var values = [
            EnvironmentKeys.path: "/usr/bin:/bin",
            EnvironmentKeys.provider: provider,
            EnvironmentKeys.toolPath: tool.path,
            EnvironmentKeys.supportDir: settings.supportFolder.path,
            EnvironmentKeys.workRoot: settings.workRoot.path,
        ]
        if let accountFolder { values[EnvironmentKeys.settingsDir] = accountFolder.path }
        if let toolDir = settings.toolDir { values[EnvironmentKeys.toolDir] = toolDir }
        values.merge(extra) { _, set in set }
        return Subprocess.environment(allowing: passed, from: settings.environment, setting: values)
    }
}

/// `LeverageRunner probe`: the runner runs one test prompt with the seat's
/// driver and exits 0 when it was answered (plan §2.2), so the four drivers
/// live in the runner only.
struct RunnerProbe: TestPrompting {
    let timings: HelperTimings

    func answers(_ entry: ProviderEntry, tool: LocatedTool, accountFolder: URL?, settings: HelperSettings) async
        -> Bool {
        let request = SubprocessRequest(
            executable: settings.runnerPath, arguments: ["probe"],
            environment: RunnerEnvironment.build(
                settings: settings, provider: entry.id, tool: tool, accountFolder: accountFolder),
            timeLimit: timings.probeLimit, gracePeriod: timings.stopGrace)
        guard let result = try? await Subprocess.run(request) else { return false }
        return result.succeeded
    }
}
