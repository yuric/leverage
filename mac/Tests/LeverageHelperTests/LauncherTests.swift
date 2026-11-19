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

/// The launcher starts and stops a seat the app runs (L62, L588, L589,
/// PK-7, CL-23). The runner is the stand-in runner, which records its
/// arguments and environment and runs until it is stopped.
@Suite("Launcher", .timeLimit(.minutes(Patience.minutes(1))))
struct LauncherTests {
    private struct Seat {
        let seat = UUID()
        let credential = UUID()
    }

    /// A start_seat request for a builder on a Claude login whose folder
    /// the add made.
    private func startRequest(_ rig: HelperRig, _ seat: Seat, provider: Provider = .claude) throws -> HelperRequest {
        if ProviderCatalog.entry(for: provider.rawValue)?.accountFolderVariable.value != nil {
            _ = try rig.folders.createFresh(for: seat.credential)
        }
        return helperRequest(
            .startSeat, seat: seat.seat, credential: seat.credential,
            params: .init(provider: provider, role: .builder, model: "model-from-the-seat", effort: nil))
    }

    private func startedRunner(_ rig: HelperRig, count: Int = 1) async throws -> [StandInRunnerStart] {
        _ = try await eventually { try rig.tools.runnerStarts().count >= count }
        return try rig.tools.runnerStarts()
    }

    @Test("the seat token is in the runner's environment and not in its arguments; the helper's is in neither")
    func tokenInEnvironmentOnly() async throws {
        let rig = try HelperRig()
        let seat = Seat()
        let launcher = rig.launcher()

        let result = await launcher.start(try startRequest(rig, seat))
        let start = try #require(try await startedRunner(rig).first)
        defer { kill(start.pid, SIGKILL); kill(start.childPid, SIGKILL) }

        #expect(result.outcome == .finished)
        #expect(start.env[EnvironmentKeys.seatToken] == MadeUp.seatToken)
        #expect(!start.argv.contains { $0.contains(MadeUp.seatToken) })
        for (name, value) in start.env {
            #expect(!value.contains(MadeUp.helperToken), "the helper's token is in \(name)")
            #expect(!value.contains("lvo_"), "an owner session is in \(name)")
        }
        #expect(start.env[EnvironmentKeys.helperToken] == nil)
        // Only the developer check may lift the account-folder rule (PV-6).
        #expect(start.env[EnvironmentKeys.devToolLogin] == nil)
        #expect(start.env["SOME_OTHER_SECRET"] == nil)

        #expect(start.env[EnvironmentKeys.seatRole] == "builder")
        #expect(start.env[EnvironmentKeys.provider] == "claude")
        #expect(start.env[EnvironmentKeys.model] == "model-from-the-seat")
        #expect(start.env[EnvironmentKeys.effort] == nil)
        #expect(start.env[EnvironmentKeys.toolPath] == rig.tools.tool("claude").path)
        #expect(start.env[EnvironmentKeys.settingsDir] == rig.folders.folder(for: seat.credential).path)
        #expect(start.env[EnvironmentKeys.apiURL] == rig.settings.apiBaseURL.absoluteString)
        #expect(start.env[EnvironmentKeys.workRoot] == rig.support.appendingPathComponent("work").path)
        #expect(start.env[EnvironmentKeys.toolDir] == rig.toolDir.path)
        #expect(start.env["HOME"] == rig.home.path)
        #expect(start.env["USER"] == "standin-user")

        // The request the launcher builds carries the token only in the
        // environment, also before it reaches the runner.
        let made = launcher.runnerRequest(
            seatID: seat.seat, seatToken: MadeUp.seatToken, params: try startRequest(rig, Seat()).params,
            tool: LocatedTool(path: rig.tools.tool("claude").path, version: "1"), accountFolder: nil)
        #expect(!made.arguments.contains { $0.contains(MadeUp.seatToken) })
        #expect(!made.executable.contains(MadeUp.seatToken))
        #expect(made.environment[EnvironmentKeys.seatToken] == MadeUp.seatToken)

        let started = try #require(rig.calls(.reportRunStarted).first)
        #expect(started.path["id"] == seat.seat.contractString)
        #expect(started.body?["credential_id"]?.stringValue == seat.credential.contractString)
        #expect(started.body?["tool_version"]?.stringValue == "0.0.1 (Claude Code stand-in)")
        #expect(!rig.everythingSent().contains(MadeUp.seatToken))
        await launcher.stopAll()
    }

    @Test("a Gemini seat gets no settings folder: Antigravity is one sign-in for the Mac")
    func noFolderForGemini() async throws {
        let rig = try HelperRig()
        let launcher = rig.launcher()

        let result = await launcher.start(try startRequest(rig, Seat(), provider: .gemini))
        let start = try #require(try await startedRunner(rig).first)

        #expect(result.outcome == .finished)
        #expect(start.env[EnvironmentKeys.settingsDir] == nil)
        #expect(start.env[EnvironmentKeys.toolPath] == rig.tools.tool("agy").path)
        await launcher.stopAll()
    }

    @Test("a stop ends the run and everything it started, and reports it stopped")
    func stopEndsTheRun() async throws {
        let rig = try HelperRig()
        let seat = Seat()
        let launcher = rig.launcher()
        _ = await launcher.start(try startRequest(rig, seat))
        let start = try #require(try await startedRunner(rig).first)
        #expect(isAlive(start.pid) && isAlive(start.childPid))

        let result = await launcher.stop(helperRequest(.stopSeat, seat: seat.seat))

        #expect(result.outcome == .finished)
        #expect(await eventually { !isAlive(start.pid) && !isAlive(start.childPid) })
        let stopped = try #require(rig.calls(.reportRunStopped).first)
        #expect(stopped.path["id"] == seat.seat.contractString)
        #expect(stopped.body?["stop_reason"]?.stringValue == "stopped")
        #expect(stopped.body?["credential_id"]?.stringValue == seat.credential.contractString)
        #expect(await launcher.runningSeats().isEmpty)
    }

    @Test("a run that ends by itself is reported stopped as finished")
    func runEndsByItself() async throws {
        let rig = try HelperRig()
        let seat = Seat()
        let launcher = rig.launcher()
        _ = await launcher.start(try startRequest(rig, seat))
        let start = try #require(try await startedRunner(rig).first)

        // The stand-in runner exits 0 when its child ends.
        kill(start.childPid, SIGKILL)

        #expect(await eventually { !rig.calls(.reportRunStopped).isEmpty })
        let stopped = try #require(rig.calls(.reportRunStopped).first)
        #expect(stopped.body?["stop_reason"]?.stringValue == "finished")
        #expect(await launcher.runningSeats().isEmpty)
    }

    @Test("a repeated seat-token answer carries no token: it is asked once more, and with none no run starts")
    func repeatedPickupStartsNoRun() async throws {
        let rig = try HelperRig()
        rig.api.script {
            $0.issueSeatToken = { request, key in
                .completed(
                    .repeated(SeatTokenPickupRepeated(helperRequestID: request, seatID: UUID())),
                    key: key.value, command: .issueSeatToken)
            }
        }
        let launcher = rig.launcher()

        let result = await launcher.start(try startRequest(rig, Seat()))

        #expect(result.outcome == .failed)
        let pickups = rig.calls(.issueSeatToken)
        #expect(pickups.count == 2)
        #expect(Set(pickups.compactMap(\.key)).count == 2)
        try await Task.sleep(for: .milliseconds(300))
        #expect(try rig.tools.runnerStarts().isEmpty)
        #expect(rig.calls(.reportRunStarted).isEmpty)
        #expect(await launcher.runningSeats().isEmpty)
    }

    @Test("a refused seat-token pickup starts no run")
    func refusedPickupStartsNoRun() async throws {
        let rig = try HelperRig()
        rig.api.script {
            $0.issueSeatToken = { _, key in
                .refused(Refusal(code: .invalidState, ruleID: nil, reason: nil), key: key.value, command: .issueSeatToken)
            }
        }
        let launcher = rig.launcher()

        let result = await launcher.start(try startRequest(rig, Seat()))

        #expect(result.outcome == .failed)
        #expect(try rig.tools.runnerStarts().isEmpty)
    }

    @Test("a seat whose tool is not installed fails to start, and no token is asked for")
    func missingToolStartsNothing() async throws {
        let rig = try HelperRig(emptyToolDir: true)
        let launcher = rig.launcher()

        let result = await launcher.start(try startRequest(rig, Seat()))

        #expect(result.outcome == .failed)
        #expect(result.checks == [HelperCheckResult(check: .toolInstalled, passed: false, failure: .notInstalled)])
        #expect(rig.calls(.issueSeatToken).isEmpty)
    }

    @Test("a Claude seat whose login has no folder fails to start: the helper never falls back to the Mac's sign-in")
    func missingFolderStartsNothing() async throws {
        let rig = try HelperRig()
        let launcher = rig.launcher()
        let request = helperRequest(
            .startSeat, seat: UUID(), credential: UUID(), params: .init(provider: .claude, role: .reviewer))

        let result = await launcher.start(request)

        #expect(result.outcome == .failed)
        #expect(result.checks == [HelperCheckResult(check: .signedIn, passed: false, failure: .notSignedIn)])
        #expect(rig.calls(.issueSeatToken).isEmpty)
    }

    @Test("a second start of a running seat replaces its run")
    func secondStartReplaces() async throws {
        let rig = try HelperRig()
        let seat = Seat()
        let launcher = rig.launcher()
        let request = try startRequest(rig, seat)
        _ = await launcher.start(request)
        let first = try #require(try await startedRunner(rig).first)

        _ = await launcher.start(helperRequest(
            .startSeat, seat: seat.seat, credential: seat.credential, params: request.params))
        let starts = try await startedRunner(rig, count: 2)

        #expect(starts.count == 2)
        #expect(await eventually { !isAlive(first.pid) })
        #expect(await launcher.runningSeats() == [seat.seat])
        await launcher.stopAll()
    }

    @Test("stopping every run ends them all and reports each stopped")
    func stopAll() async throws {
        let rig = try HelperRig()
        let launcher = rig.launcher()
        _ = await launcher.start(try startRequest(rig, Seat()))
        _ = await launcher.start(try startRequest(rig, Seat(), provider: .codex))
        let starts = try await startedRunner(rig, count: 2)

        await launcher.stopAll()

        #expect(starts.count == 2)
        for start in starts {
            #expect(await eventually { !isAlive(start.pid) && !isAlive(start.childPid) })
        }
        #expect(rig.calls(.reportRunStopped).count == 2)
        #expect(await launcher.runningSeats().isEmpty)
    }

    @Test("each run's output goes to its own log file in the support folder")
    func runLog() async throws {
        let rig = try HelperRig()
        let seat = Seat()
        let launcher = rig.launcher()
        _ = await launcher.start(try startRequest(rig, seat))
        _ = try await startedRunner(rig)

        let log = rig.support.appendingPathComponent("logs/seat-\(seat.seat.contractString).log")
        #expect(FileManager.default.fileExists(atPath: log.path))
        await launcher.stopAll()
    }
}
