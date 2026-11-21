import Foundation
import LeverageKit

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The helper put together: the request loop, and the parts each kind of
/// request goes to. `run()` ends on `401` (exit code 3, after stopping the
/// runs) or after `shutdown()` (exit code 0).
final class HelperRuntime: Sendable {
    let api: any HelperAPI
    let settings: HelperSettings
    let timings: HelperTimings
    let log: Log
    let launcher: Launcher
    let checks: AddChecks
    let signInAgain: SignInAgain
    let installer: ToolInstaller
    let cleanup: CredentialCleanup
    private let loopTask = LoopTask()

    init(
        api: any HelperAPI, settings: HelperSettings, timings: HelperTimings, log: Log,
        prober: (any TestPrompting)? = nil, fetch: ToolInstaller.Fetch? = nil,
        pending: PendingTokens = PendingTokens(), vault: any TokenVault = MemoryTokenVault(),
        http: ProviderHTTP = ProviderHTTP(), usageReaders: UsageReaders.Lookup = UsageReaders.reader(for:),
        testedVersions: @escaping @Sendable (Provider) -> [String] = { $0.testedToolVersions }
    ) {
        self.api = api
        self.settings = settings
        self.timings = timings
        self.log = log
        launcher = Launcher(api: api, settings: settings, timings: timings, log: log)
        let prober = prober ?? RunnerProbe(timings: timings)
        checks = AddChecks(api: api, settings: settings, timings: timings, prober: prober, log: log)
        signInAgain = SignInAgain(api: api, settings: settings, timings: timings, prober: prober, log: log)
        cleanup = CredentialCleanup(
            folders: AccountFolders(supportFolder: settings.supportFolder), pending: pending, vault: vault,
            requests: RunningRequests(), log: log)
        installer = ToolInstaller(settings: settings, timings: timings, fetch: fetch)
    }

    /// Does one request; nil when the helper is stopping.
    func handle(_ request: HelperRequest) async -> HelperRequestResult? {
        let result: HelperRequestResult
        switch request.kind {
        case .startSeat: result = await launcher.start(request)
        case .stopSeat: result = await launcher.stop(request)
        case .runAddChecks: result = await checks.add(request)
        case .verify: result = await checks.verify(request)
        case .installTool: result = await installer.handle(request)
        case .openSignIn: result = await signInAgain.run(request)
        case .readUsage:
            // Usage readers are milestone 6's.
            log.warning("\(request.kind.rawValue) is not done by this helper")
            result = HelperRequestResult(outcome: .failed, checks: [], toolVersion: nil)
        }
        return Task.isCancelled ? nil : result
    }

    /// Runs the request loop until `401` or `shutdown()`, and answers the
    /// helper's exit code.
    func run() async -> Int32 {
        let loop = RequestLoop(api: api, timings: timings, log: log) { [self] request in
            await handle(request)
        }
        let task = Task { await loop.run() }
        guard loopTask.set(task) else {
            task.cancel()
            return HelperExitCode.stopped
        }
        let end = await task.value
        if end == .unauthorized { await launcher.stopAll() }
        return HelperExitCode.code(for: end)
    }

    /// Ends the loop and every request in it, and stops every run; each
    /// run releases what it holds and is reported stopped.
    func shutdown() async {
        loopTask.cancel()
        await launcher.stopAll()
    }
}

/// The request loop's task, which `shutdown()` may cancel before or after
/// it starts.
private final class LoopTask: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<LoopEnd, Never>?
    private var cancelled = false

    /// False when shutdown came first.
    func set(_ task: Task<LoopEnd, Never>) -> Bool {
        lock.withLock {
            guard !cancelled else { return false }
            self.task = task
            return true
        }
    }

    func cancel() {
        let task = lock.withLock {
            cancelled = true
            return self.task
        }
        task?.cancel()
    }
}

/// The helper's program: reads its configuration, starts the loop, stops
/// its runs on a stop signal or when the app is gone, and exits.
enum HelperMain {
    static func run() async -> Int32 {
        let log = Log(component: "helper")
        let executable = Bundle.main.executableURL?.resolvingSymlinksInPath().path
            ?? CommandLine.arguments.first ?? "LeverageHelper"
        let configuration: HelperConfiguration
        do {
            configuration = try HelperConfiguration(
                environment: ProcessInfo.processInfo.environment, executablePath: executable)
        } catch {
            log.error("no helper token in the environment; the helper does not start")
            return HelperExitCode.configuration
        }
        let api = HelperClient(baseURL: configuration.settings.apiBaseURL, helperToken: configuration.helperToken)
        let runtime = HelperRuntime(api: api, settings: configuration.settings, timings: .standard, log: log)

        let stopping = Stopping(runtime: runtime)
        var signals: [any DispatchSourceSignal] = []
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler {
                log.info("asked to stop")
                stopping.begin()
            }
            source.resume()
            signals.append(source)
        }
        let watch = HelperParent.watch {
            log.warning("the app that started the helper is gone; stopping")
            stopping.begin()
        }

        log.info("started, version \(leverageMacVersion)")
        let code = await runtime.run()
        await stopping.finished()
        watch?.cancel()
        for source in signals { source.cancel() }
        log.info("stopped")
        return code
    }
}

/// The helper's watch on the app that started it (PK-8), as a runner's on
/// its helper (`RunnerParent`).
enum HelperParent {
    /// Watches `parent`. When there is no parent to watch (it is already
    /// launchd, pid 1: the app died between starting the helper and the
    /// helper's first lines, since the app starts the helper itself), `onGone`
    /// is called at once and the answer is nil, so no helper runs on with
    /// its token unwatched.
    static func watch(
        parent: pid_t = getppid(), interval: Duration = .seconds(2), onGone: @escaping @Sendable () -> Void
    ) -> ParentWatch? {
        guard parent > 1 else {
            onGone()
            return nil
        }
        let watch = ParentWatch(watching: parent, interval: interval, onGone: onGone)
        watch.start()
        return watch
    }
}

/// Runs `shutdown()` once, whatever asks first.
private final class Stopping: @unchecked Sendable {
    private let runtime: HelperRuntime
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    init(runtime: HelperRuntime) { self.runtime = runtime }

    func begin() {
        lock.withLock {
            guard task == nil else { return }
            task = Task { [runtime] in await runtime.shutdown() }
        }
    }

    func finished() async {
        let task = lock.withLock { self.task }
        await task?.value
    }
}
