import Foundation
import LeverageKit

/// What the helper works with, without its token: where the API is, the
/// support folder, the runner program, the folder of stand-in tools when a
/// test sets one, and the helper's own environment, which every child's
/// allow-listed environment is built from (CL-10).
struct HelperSettings: Sendable {
    var apiBaseURL: URL
    /// `~/Library/Application Support/leverage`, or `LEVERAGE_SUPPORT_DIR`.
    var supportFolder: URL
    var runnerPath: String
    /// When set, the only folder a provider's tool is looked for in (PV-3).
    var toolDir: String?
    /// The helper's environment, without the helper's token.
    var environment: [String: String]

    var home: String { environment[EnvironmentKeys.home] ?? NSHomeDirectory() }
    /// `<support folder>/logs`, where each run's output goes (CL-29).
    var logsFolder: URL { supportFolder.appendingPathComponent("logs", isDirectory: true) }
    /// `<support folder>/work`, where the runner makes task folders (CL-7).
    var workRoot: URL { supportFolder.appendingPathComponent("work", isDirectory: true) }
}

/// The helper's inputs from its environment (plan §2.4). It fails closed
/// without the helper's token (PK-4).
struct HelperConfiguration: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    enum Failure: Error, Equatable {
        case missingHelperToken
    }

    let settings: HelperSettings
    let helperToken: String

    /// `executablePath` is the helper's own program; the runner is looked
    /// for beside it unless `LEVERAGE_RUNNER_PATH` names it.
    init(environment: [String: String], executablePath: String) throws {
        guard let token = environment[EnvironmentKeys.helperToken], !token.isEmpty else {
            throw Failure.missingHelperToken
        }
        helperToken = token

        func value(_ name: String) -> String? {
            environment[name].flatMap { $0.isEmpty ? nil : $0 }
        }
        let home = value(EnvironmentKeys.home) ?? NSHomeDirectory()
        let support = value(EnvironmentKeys.supportDir)
            ?? "\(home)/Library/Application Support/leverage"
        let runner = value(EnvironmentKeys.runnerPath)
            ?? URL(fileURLWithPath: executablePath).deletingLastPathComponent()
                .appendingPathComponent("LeverageRunner").path
        var own = environment
        own[EnvironmentKeys.helperToken] = nil
        settings = HelperSettings(
            apiBaseURL: Configuration(environment: environment).apiBaseURL,
            supportFolder: URL(fileURLWithPath: support, isDirectory: true),
            runnerPath: runner,
            toolDir: value(EnvironmentKeys.toolDir),
            environment: own)
    }

    var description: String {
        "HelperConfiguration(api: \(settings.apiBaseURL.absoluteString), support: \(settings.supportFolder.path), "
            + "runner: \(settings.runnerPath), helperToken: [removed])"
    }

    var debugDescription: String { description }
}

/// How long the helper waits and how often it looks. `standard` is what it
/// runs with; tests shorten them.
struct HelperTimings: Sendable {
    /// Between two looks at a status or for a tool (CL-19).
    var lookEvery: Duration = .seconds(2)
    /// Between two test prompts where the prompt is the look (PV-4).
    var promptEvery: Duration = .seconds(15)
    /// The longest wait for the owner to sign in or install (CL-19).
    var waitAtMost: Duration = .seconds(600)
    /// The limit of a version or status command (PV-3).
    var commandLimit: Duration = .seconds(10)
    /// The limit of one `LeverageRunner probe`.
    var probeLimit: Duration = .seconds(300)
    /// The limit of one installer run.
    var installLimit: Duration = .seconds(600)
    /// How long a stopped runner is given before its group is ended (CL-23).
    var stopGrace: Duration = StopTimings.runnerStopGrace
    /// The pause after a failed call; never more than 2 seconds (CL-31).
    var pauseAfterError: Duration = .seconds(1)
    /// The `wait` of `GET /v1/helper/next`.
    var longPollSeconds: Int = 30
    /// A run's log is replaced when it passes this size (CL-29).
    var logLimitBytes: Int = 5 << 20
    /// How often a run's log size is looked at.
    var logCheckEvery: Duration = .seconds(60)

    static let standard = HelperTimings()
}

/// The helper's exit codes.
enum HelperExitCode {
    /// Stopped by a signal, or because the app is gone.
    static let stopped: Int32 = 0
    /// The configuration was not usable (no helper token).
    static let configuration: Int32 = 2
    /// The helper's token was ended (`401`); the app issues another (PK-4).
    static let unauthorized: Int32 = 3

    static func code(for end: LoopEnd) -> Int32 {
        switch end {
        case .unauthorized: unauthorized
        case .cancelled: stopped
        }
    }
}
