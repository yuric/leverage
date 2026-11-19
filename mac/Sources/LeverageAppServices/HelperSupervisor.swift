import Foundation
import LeverageKit

/// Starts the helper and keeps it running while the app is open (plan
/// PK-4, PK-8). It sends `issue_helper_token`, starts `LeverageHelper` as a
/// child process with the token and the API address in its environment,
/// and keeps the token nowhere else: not in a file, not in the Keychain,
/// never in a log or an argument. When the helper exits on its own (code 3
/// when its token ended), a new token is issued with a new key and the
/// helper is started again, at most three times in a minute; after that it
/// stops trying until `tryAgain()`. `stop()` asks the helper to stop and
/// waits for it.
///
/// The helper's standard output and standard error go to
/// `<support folder>/logs/helper.log`, which is replaced by a new file at a
/// start once it has passed 5 MB (the old one is kept as `helper.log.1`).
public actor HelperSupervisor: HelperSupervising {
    public struct Configuration: Sendable {
        /// `Contents/MacOS/LeverageHelper` in the app bundle.
        public var helperProgram: URL
        public var supportFolder: URL
        /// The app's own environment: the helper gets only the names of
        /// `passedNames` from it.
        public var environment: [String: String]
        /// The `name` `issue_helper_token` requires.
        public var helperName = "This Mac"
        public var restartLimit = 3
        public var restartWindow: TimeInterval = 60
        /// The pause before a start after a failed one.
        public var restartDelay: Duration = .seconds(1)
        /// How long the helper is given to stop before it is forced.
        public var stopGracePeriod: Duration = .seconds(10)
        public var logLimitBytes = 5_000_000

        public init(helperProgram: URL, supportFolder: URL, environment: [String: String]) {
            self.helperProgram = helperProgram
            self.supportFolder = supportFolder
            self.environment = environment
        }

        /// What the helper may be given from the app's environment: what a
        /// provider's tool needs from it (ProviderCatalog builds each tool's
        /// own environment from the helper's), and the two settings that
        /// point the helper at stand-ins in a test run.
        public static let passedNames = [
            EnvironmentKeys.home, EnvironmentKeys.path, EnvironmentKeys.tmpdir, EnvironmentKeys.lang,
            EnvironmentKeys.user, EnvironmentKeys.toolDir, EnvironmentKeys.runnerPath,
        ]

        /// The helper next to the app's own program, as the bundle has it.
        public static func bundledHelper(mainExecutable: URL? = Bundle.main.executableURL) -> URL? {
            mainExecutable?.deletingLastPathComponent().appendingPathComponent("LeverageHelper")
        }
    }

    private let configuration: Configuration
    private let now: @Sendable () -> Date
    private let log: Log

    private var current: HelperState = .notStarted
    private var apiBaseURL: URL?
    private var issuer: (any HelperTokenIssuing)?
    private var child: RunningSubprocess?
    /// Changes whenever a child is replaced or stopped, so that the end of
    /// an old child is not taken for the end of the current one.
    private var generation = 0
    private var restarts: [Date] = []
    private var stopping = false
    /// Changes at every `start` and `stop`: a launch that was waiting for
    /// its token when the owner stopped (and perhaps started again) gives
    /// up instead of starting a second helper.
    private var epoch = 0

    public init(
        configuration: Configuration,
        now: @escaping @Sendable () -> Date = { Date() },
        log: Log = Log(component: "app")
    ) {
        self.configuration = configuration
        self.now = now
        self.log = log
    }

    public func state() async -> HelperState { current }

    public func start(apiBaseURL: URL, issuer: any HelperTokenIssuing) async -> HelperState {
        switch current {
        case .starting, .running, .restarting: return current
        case .notStarted, .stoppedTrying, .stopped: break
        }
        self.apiBaseURL = apiBaseURL
        self.issuer = issuer
        stopping = false
        restarts = []
        epoch += 1
        return await launch(restart: nil)
    }

    public func tryAgain() async -> HelperState {
        guard current == .stoppedTrying, let apiBaseURL, let issuer else { return current }
        return await start(apiBaseURL: apiBaseURL, issuer: issuer)
    }

    public func stop() async {
        stopping = true
        epoch += 1
        generation += 1
        if let running = child {
            child = nil
            running.stop()
            _ = await running.wait()
            log.info("the helper stopped")
        }
        current = .stopped
    }

    // MARK: - Starting

    private func launch(restart attempt: Int?) async -> HelperState {
        current = attempt.map { .restarting(attempt: $0) } ?? .starting
        guard let apiBaseURL, let issuer else { return current }
        let mineEpoch = epoch
        // No token is issued for a helper that cannot run; trying again
        // would not help either.
        guard DockerLocator.fileIsExecutable(configuration.helperProgram.path) else {
            log.error("no helper program at \(configuration.helperProgram.path)")
            current = .stoppedTrying
            return current
        }

        guard let token = await issueToken(issuer) else { return await restartOrGiveUp() }
        // The owner may have quit, or quit and started again, while the
        // token was being issued.
        guard !stopping, epoch == mineEpoch else { return current }

        let started: RunningSubprocess
        do {
            started = try Subprocess.start(request(apiBaseURL: apiBaseURL, token: token))
        } catch {
            log.error("the helper could not be started: \(error)")
            return await restartOrGiveUp()
        }
        generation += 1
        let mine = generation
        child = started
        current = .running
        log.info("the helper started (process \(started.processID))")
        Task { [weak self] in
            let result = await started.wait()
            await self?.ended(result, generation: mine)
        }
        return current
    }

    /// The token of a first answer. A repeated answer carries none, so the
    /// token is issued once more with a new key; a failure gives nil.
    private func issueToken(_ issuer: any HelperTokenIssuing) async -> String? {
        for _ in 0..<2 {
            do {
                if let token = try await issuer.issueHelperToken(
                    name: configuration.helperName, idempotencyKey: IdempotencyKey().value) {
                    return token
                }
                log.warning("issue_helper_token answered a repeat with no token; issuing again with a new key")
            } catch {
                log.error("issue_helper_token failed: \(error)")
                return nil
            }
        }
        return nil
    }

    private func ended(_ result: SubprocessResult, generation ended: Int) async {
        guard ended == generation, !stopping else { return }
        child = nil
        switch result.termination {
        case .exited(3): log.warning("the helper's token ended (exit 3)")
        case .exited(let code): log.warning("the helper exited by itself (exit \(code))")
        case .signaled(let signal): log.warning("the helper ended on signal \(signal)")
        }
        _ = await restartOrGiveUp()
    }

    /// Starts the helper again unless it was started again three times in
    /// the last minute already.
    private func restartOrGiveUp() async -> HelperState {
        guard !stopping else { return current }
        let time = now()
        restarts.removeAll { time.timeIntervalSince($0) >= configuration.restartWindow }
        guard restarts.count < configuration.restartLimit else {
            log.error("the helper failed \(restarts.count + 1) times within a minute; not starting it again")
            current = .stoppedTrying
            return current
        }
        restarts.append(time)
        let attempt = restarts.count
        let mineEpoch = epoch
        current = .restarting(attempt: attempt)
        if configuration.restartDelay > .zero {
            try? await Task.sleep(for: configuration.restartDelay)
        }
        guard !stopping, epoch == mineEpoch, current == .restarting(attempt: attempt) else { return current }
        return await launch(restart: attempt)
    }

    // MARK: - The child

    private var logsFolder: URL { configuration.supportFolder.appendingPathComponent("logs", isDirectory: true) }

    /// The helper runs through `/bin/sh`, which sends its two outputs to
    /// the log file and then replaces itself with the helper (`exec`), so
    /// the process is the helper's own and its parent is the app. The
    /// token is only in the environment.
    private func request(apiBaseURL: URL, token: String) -> SubprocessRequest {
        let logFile = prepareLog()
        let environment = Subprocess.environment(
            allowing: Configuration.passedNames,
            from: configuration.environment,
            setting: [
                EnvironmentKeys.apiURL: apiBaseURL.absoluteString,
                EnvironmentKeys.helperToken: token,
                EnvironmentKeys.supportDir: configuration.supportFolder.path,
            ])
        return SubprocessRequest(
            executable: "/bin/sh",
            arguments: ["-c", "exec \"$0\" >>\"$1\" 2>&1", configuration.helperProgram.path, logFile.path],
            environment: environment,
            workingDirectory: configuration.supportFolder.path,
            gracePeriod: configuration.stopGracePeriod)
    }

    /// Makes the logs folder and replaces a log past its limit.
    private func prepareLog() -> URL {
        let manager = FileManager.default
        try? manager.createDirectory(
            at: logsFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = logsFolder.appendingPathComponent("helper.log")
        let size = (try? manager.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
        if size > configuration.logLimitBytes {
            let old = logsFolder.appendingPathComponent("helper.log.1")
            try? manager.removeItem(at: old)
            try? manager.moveItem(at: file, to: old)
        }
        if !manager.fileExists(atPath: file.path) {
            manager.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        return file
    }
}
