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

// What the helper's tests share: a folder of their own with a copy of the
// stand-ins, the helper's settings pointed at it, short timings, and a fake
// API that answers every report. No test reaches a real provider's tool:
// `toolDir` is always set, so the stand-ins are the only tools there are.

/// Made-up tokens, shaped like leverage's (IN-18), so a test can look for
/// them where they must not be.
enum MadeUp {
    static let helperToken = "lvh_madeUpHelperTokenForTestsOnly0000"
    static let seatToken = "lvs_madeUpSeatTokenForTestsOnly00000"
}

/// Timings short enough for a test; the order between them is the real one.
/// The looks are short; the limits are only ceilings, which a passing test
/// never reaches, and are wide because a tool's start can take seconds when
/// the whole package's tests run at once on a busy Mac, and wider still by
/// the run's patience (a test that needs a wait to run out sets its own
/// short one).
let fastTimings = HelperTimings(
    lookEvery: .milliseconds(50),
    promptEvery: .milliseconds(100),
    waitAtMost: Patience.scaled(.seconds(45)),
    commandLimit: Patience.scaled(.seconds(45)),
    probeLimit: Patience.scaled(.seconds(60)),
    installLimit: Patience.scaled(.seconds(60)),
    stopGrace: .seconds(3),
    pauseAfterError: .milliseconds(50),
    longPollSeconds: 1,
    logLimitBytes: 5 << 20,
    logCheckEvery: .seconds(60))

/// One test's folder, stand-ins and settings.
final class HelperRig: @unchecked Sendable {
    let folder: TemporaryFolder
    let tools: StandInTools
    let home: URL
    let support: URL
    let api = FakeHelperAPI()
    var settings: HelperSettings

    init(prefix: String = "helper-test", runner: URL? = nil, emptyToolDir: Bool = false) throws {
        folder = try TemporaryFolder(prefix: prefix)
        tools = try StandIns.copy(into: folder.url)
        home = try folder.folder("home")
        support = try folder.folder("support")
        let toolDir = emptyToolDir ? try folder.folder("empty-tools") : tools.bin
        settings = HelperSettings(
            apiBaseURL: URL(string: "http://127.0.0.1:47199")!,
            supportFolder: support,
            runnerPath: (runner ?? tools.runner).path,
            toolDir: toolDir.path,
            environment: [
                "HOME": home.path, "PATH": "/usr/bin:/bin", "TMPDIR": folder.url.path, "LANG": "en_US.UTF-8",
                "USER": "standin-user",
                EnvironmentKeys.helperToken: MadeUp.helperToken,
                EnvironmentKeys.devToolLogin: "1",
                "SOME_OTHER_SECRET": "lvo_madeUpOwnerSessionForTestsOnly000",
            ])
        api.answersEveryReport()
    }

    var toolDir: URL { URL(fileURLWithPath: settings.toolDir!) }
    var folders: AccountFolders { AccountFolders(supportFolder: support) }

    func checks(prober: any TestPrompting = StandInPrompt(), timings: HelperTimings = fastTimings) -> AddChecks {
        AddChecks(api: api, settings: settings, timings: timings, prober: prober, log: quietLog)
    }

    func launcher(timings: HelperTimings = fastTimings) -> Launcher {
        Launcher(api: api, settings: settings, timings: timings, log: quietLog)
    }

    /// Every body the helper sent, as one JSON text, to look for what must
    /// never be in it.
    func everythingSent() -> String {
        api.calls.compactMap { call in
            call.body.flatMap { try? String(decoding: JSONEncoder().encode($0), as: UTF8.self) }
        }.joined(separator: "\n")
    }

    /// The progress reports of one request, in order.
    func progress(of request: UUID) -> [HelperCheckProgress] {
        api.calls.filter { $0.operation == .reportRequestProgress && $0.path["id"] == request.contractString }
            .compactMap { call in
                call.body.flatMap { body in
                    (try? JSONEncoder().encode(body)).flatMap { try? JSONDecoder().decode(HelperCheckProgress.self, from: $0) }
                }
            }
    }

    func calls(_ operation: ContractOperation) -> [FakeCall] {
        api.calls.filter { $0.operation == operation }
    }
}

/// A log that writes nowhere, for tests that do not read it.
let quietLog = Log(component: "helper-test", write: { _ in })

/// A log whose lines a test can read.
final class CapturedLog: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    var log: Log { Log(component: "helper-test", write: { [self] line in lock.withLock { lines.append(line) } }) }
    var text: String { lock.withLock { lines.joined() } }
}

extension FakeHelperAPI {
    /// Every report completes; `next` answers nothing.
    func answersEveryReport() {
        script {
            $0.next = { _ in
                try await Task.sleep(for: .milliseconds(20))
                return HelperNext(request: nil)
            }
            $0.reportRequestProgress = { _, _, key in .completed(.object([:]), key: key.value, command: .reportRequestProgress) }
            $0.reportRequestResult = { _, _, key in .completed(.object([:]), key: key.value, command: .reportRequestResult) }
            $0.reportRunStarted = { _, _, key in .completed(.object([:]), key: key.value, command: .reportRunStarted) }
            $0.reportRunStopped = { _, _, key in .completed(.object([:]), key: key.value, command: .reportRunStopped) }
            $0.issueSeatToken = { request, key in
                .completed(
                    .shown(SeatTokenPickup(helperRequestID: request, seatID: UUID(), seatToken: MadeUp.seatToken)),
                    key: key.value, command: .issueSeatToken)
            }
        }
    }
}

/// The answering check against a stand-in, without the runner: the test
/// prompt of PV-2 run straight at the stand-in tool, answered when it exits
/// 0. (The helper itself asks `LeverageRunner probe`; `RunnerProbeTests`
/// proves how it does.)
struct StandInPrompt: TestPrompting {
    func answers(_ entry: ProviderEntry, tool: LocatedTool, accountFolder: URL?, settings: HelperSettings) async -> Bool {
        let prompt = "Reply with the single word ready."
        let arguments: [String]
        switch entry.id {
        case "codex": arguments = ["exec", prompt, "--json", "--skip-git-repo-check"]
        default: arguments = ["-p", prompt]
        }
        let locator = ToolLocator(settings: settings, timings: fastTimings)
        guard let result = try? await Subprocess.run(SubprocessRequest(
            executable: tool.path, arguments: arguments,
            environment: locator.toolEnvironment(entry, toolPath: tool.path, accountFolder: accountFolder),
            timeLimit: Patience.scaled(.seconds(20)))) else { return false }
        return result.succeeded
    }
}

/// A prober with a fixed answer.
struct FixedPrompt: TestPrompting {
    let answer: Bool
    func answers(_ entry: ProviderEntry, tool: LocatedTool, accountFolder: URL?, settings: HelperSettings) async -> Bool {
        answer
    }
}

/// A request as the server would hand it over.
func helperRequest(
    _ kind: HelperRequestKind, seat: UUID? = nil, credential: UUID? = nil, params: HelperRequestParams = .init(),
    id: UUID = UUID()
) -> HelperRequest {
    HelperRequest(
        id: id, kind: kind, seatID: seat, credentialID: credential, state: .pickedUp, requestedAt: Date(),
        pickedUpAt: Date(), params: params)
}

/// Waits until `condition` holds, looking every 20 ms, for at most
/// `seconds` times the run's patience; true when it held.
func eventually(within seconds: Double = 45, _ condition: () throws -> Bool) async rethrows -> Bool {
    let deadline = Date().addingTimeInterval(Patience.seconds(seconds))
    while Date() < deadline {
        if try condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return try condition()
}

/// True while a process with this id exists (a zombie counts as gone).
func isAlive(_ pid: Int32) -> Bool {
    guard kill(pid, 0) == 0 else { return false }
    #if canImport(Darwin)
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&name, 4, &info, &size, nil, 0) == 0, size > 0 else { return false }
    return info.kp_proc.p_stat != SZOMB
    #else
    guard let stat = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8) else { return false }
    return !stat.contains(") Z ")
    #endif
}

/// Starts a program that runs until it is ended, for a test that needs a
/// process to watch.
func startSleeper() throws -> RunningSubprocess {
    try Subprocess.start(SubprocessRequest(
        executable: "/bin/sleep", arguments: ["60"], environment: [:], gracePeriod: .seconds(1)))
}
