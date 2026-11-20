import Foundation
import LeverageKit

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Starts and stops the seats the app runs (L62, L588, L589, PK-7, CL-23).
///
/// A start finds the tool and the folder of the request's credential, picks
/// up a fresh seat token, and puts it only into the environment of the
/// `LeverageRunner` process it starts: never into an argument, a file, a log
/// or a report. The helper's own token is never passed on. The run is given
/// the credential, the model and effort of the request's `params`, and the
/// task or review to continue (plan HD-1, HD-9).
///
/// A start for a seat whose run is alive hands over (HD-2): the new token
/// first, which ends the old run's, then the old run is stopped as any run
/// is, then the new one starts; the old run's end is not reported (HD-10).
///
/// When a run ends by a stop or by itself, `report_run_stopped` says so;
/// when it ends with code 5 and its report line, the account stopped and
/// `InterruptionReporter` sends `report_limit` or `report_signed_out`
/// instead (HD-6, HD-10).
final class Launcher: Sendable {
    let api: any HelperAPI
    let settings: HelperSettings
    let timings: HelperTimings
    let log: Log
    let registry = RunRegistry()
    private let now: @Sendable () -> Date

    init(
        api: any HelperAPI, settings: HelperSettings, timings: HelperTimings, log: Log,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.api = api
        self.settings = settings
        self.timings = timings
        self.log = log
        self.now = now
    }

    private var locator: ToolLocator { ToolLocator(settings: settings, timings: timings) }

    func runningSeats() async -> [UUID] { await registry.seats }

    // MARK: Start

    func start(_ request: HelperRequest) async -> HelperRequestResult {
        func failed(_ checks: [HelperCheckResult] = [], version: String? = nil) -> HelperRequestResult {
            HelperRequestResult(outcome: .failed, checks: checks, toolVersion: version)
        }
        guard let seat = request.seatID, let credential = request.credentialID,
              request.params.role != nil, let provider = request.params.provider,
              let entry = ProviderCatalog.entry(for: provider.rawValue)
        else {
            log.error("start_seat request \(request.id.contractString) lacks its seat, login or role")
            return failed()
        }
        guard let tool = await locator.locate(entry) else {
            return failed([HelperCheckResult(check: .toolInstalled, passed: false, failure: .notInstalled)])
        }
        var accountFolder: URL?
        if entry.accountFolderVariable.value != nil {
            // Never the Mac's own sign-in: only the folder the add made.
            accountFolder = AccountFolders(supportFolder: settings.supportFolder).existing(for: credential)
            if accountFolder == nil {
                return failed(
                    [HelperCheckResult(check: .signedIn, passed: false, failure: .notSignedIn)],
                    version: tool.version)
            }
        }

        // The token first (HD-2): when it is not given, a run of the seat
        // that is alive goes on as it was.
        guard let token = await pickUpSeatToken(request) else { return failed(version: tool.version) }
        // A start of a seat that is running hands its run over: the old
        // run's token has just ended, so its release is refused and it
        // gives nothing back (HD-2).
        if let earlier = await registry.run(for: seat) {
            await earlier.handOver()
            await registry.remove(earlier)
            log.info("handed the run of seat \(seat.contractString) over to a new run")
        }

        let process: RunningSubprocess
        do {
            try FileManager.default.createDirectory(at: settings.logsFolder, withIntermediateDirectories: true)
            process = try Subprocess.start(runnerRequest(
                seatID: seat, seatToken: token, params: request.params, tool: tool, accountFolder: accountFolder,
                credentialID: credential))
        } catch {
            log.error("could not start the run of seat \(seat.contractString)")
            return failed(version: tool.version)
        }
        let run = SeatRun(seatID: seat, credentialID: credential, toolVersion: tool.version, process: process)
        // In the registry before it is watched, so a run that ends at once
        // is not left in it.
        await registry.add(run)
        run.watch(with: Task { await self.watchUntilEnd(run) })
        log.info("started the run of seat \(seat.contractString)")

        await send(.reportRunStarted, seat: seat) { key in
            try await self.api.reportRunStarted(
                seatID: seat,
                RunStartedReport(credentialID: credential, observedAt: self.now(), toolVersion: tool.version),
                key: key)
        }
        return HelperRequestResult(outcome: .finished, checks: [], toolVersion: tool.version)
    }

    /// The seat's fresh token (PK-7). A repeated answer carries none, so it
    /// is asked once more with a new key; a second one starts no run.
    private func pickUpSeatToken(_ request: HelperRequest) async -> String? {
        for _ in 0..<2 {
            do {
                let outcome = try await api.issueSeatToken(requestID: request.id, key: IdempotencyKey())
                switch try outcome.completedResult() {
                case .shown(let pickup)?: return pickup.seatToken
                case .repeated?, nil: continue
                }
            } catch {
                log.warning("the seat token of request \(request.id.contractString) was not given")
                return nil
            }
        }
        log.warning("the seat token of request \(request.id.contractString) was not given")
        return nil
    }

    /// The runner's process: its program behind `/bin/sh`, which only sends
    /// its standard error, its log, to the seat's log file and then becomes
    /// the runner. Its standard output stays on the pipe the helper reads,
    /// where the runner prints its one report line (HD-6). The seat token is
    /// in the environment and nowhere else.
    func runnerRequest(
        seatID: UUID, seatToken: String, params: HelperRequestParams, tool: LocatedTool, accountFolder: URL?,
        credentialID: UUID? = nil
    ) -> SubprocessRequest {
        var values = [
            EnvironmentKeys.apiURL: settings.apiBaseURL.absoluteString,
            EnvironmentKeys.seatToken: seatToken,
        ]
        if let credentialID { values[EnvironmentKeys.credentialID] = credentialID.contractString }
        if let role = params.role { values[EnvironmentKeys.seatRole] = role.rawValue }
        if let model = params.model, !model.isEmpty { values[EnvironmentKeys.model] = model }
        if let effort = params.effort, !effort.isEmpty { values[EnvironmentKeys.effort] = effort }
        if let task = params.taskID {
            values[EnvironmentKeys.continueTaskID] = task.contractString
        } else if let review = params.reviewID {
            values[EnvironmentKeys.continueReviewID] = review.contractString
        }
        let environment = RunnerEnvironment.build(
            settings: settings, provider: params.provider?.rawValue ?? "", tool: tool,
            accountFolder: accountFolder, setting: values)
        return SubprocessRequest(
            executable: "/bin/sh",
            arguments: ["-c", #"log=$1; shift; exec "$@" 2>>"$log""#, "sh", logFile(for: seatID).path,
                        settings.runnerPath],
            environment: environment,
            gracePeriod: timings.stopGrace,
            maximumOutputBytes: Self.runnerOutputLimit)
    }

    /// The most of the runner's standard output kept in memory. It prints
    /// one short line, and only when its account stops.
    static let runnerOutputLimit = 1 << 20

    func logFile(for seat: UUID) -> URL {
        settings.logsFolder.appendingPathComponent("seat-\(seat.contractString).log")
    }

    // MARK: Stop

    func stop(_ request: HelperRequest) async -> HelperRequestResult {
        if let seat = request.seatID, let run = await registry.run(for: seat) {
            await run.stop()
            await registry.remove(run)
            log.info("stopped the run of seat \(seat.contractString)")
        }
        return HelperRequestResult(outcome: .finished, checks: [], toolVersion: nil)
    }

    /// Stops every run at once and waits until each end is reported.
    func stopAll() async {
        let runs = await registry.all
        await withTaskGroup(of: Void.self) { group in
            for run in runs {
                group.addTask {
                    await run.stop()
                    await self.registry.remove(run)
                }
            }
        }
    }

    // MARK: The end of a run

    private func watchUntilEnd(_ run: SeatRun) async {
        let logWatch = Task { await self.keepLogSmall(run.seatID) }
        defer { logWatch.cancel() }
        let result = await run.process.wait()
        await registry.remove(run)
        if run.wasHandedOver {
            // The new run's report_run_started follows (HD-10).
            log.info("the run of seat \(run.seatID.contractString) ended: handed over")
            return
        }
        if result.termination == .exited(Self.accountStoppedCode) {
            if let end = try? RunEndReport(lastLineOf: result.standardOutput) {
                log.info("the run of seat \(run.seatID.contractString) ended: \(end.kind.rawValue)")
                _ = await InterruptionReporter(api: api, timings: timings, log: log)
                    .report(end, seatID: run.seatID, credentialID: run.credentialID, toolVersion: run.toolVersion)
                return
            }
            // HD-6: a code 5 with no readable line is code 4.
            log.warning("the run of seat \(run.seatID.contractString) gave code 5 with no readable report line")
        }
        let reason = Self.stopReason(result, stopAsked: run.stopWasAsked)
        log.info("the run of seat \(run.seatID.contractString) ended: \(reason.rawValue)")
        await send(.reportRunStopped, seat: run.seatID) { key in
            try await self.api.reportRunStopped(
                seatID: run.seatID,
                RunStoppedReport(credentialID: run.credentialID, observedAt: self.now(), stopReason: reason),
                key: key)
        }
    }

    /// The runner's exit code when its account stopped, a limit or a
    /// sign-out, with its report line on standard output (HD-6).
    static let accountStoppedCode: Int32 = 5

    /// `stopped` when the helper stopped it, `finished` when the runner
    /// exited 0 by itself, `error` otherwise (three failed tool runs, CL-22,
    /// a code 5 with no readable report line, HD-6, or a crash).
    static func stopReason(_ result: SubprocessResult, stopAsked: Bool) -> RunStopReason {
        if stopAsked || result.endedBy == .stop { return .stopped }
        if result.termination == .exited(0) { return .finished }
        return .error
    }

    /// Replaces the seat's log when it passes the limit (CL-29): at the
    /// start and then every `logCheckEvery`. The runner appends, so it
    /// goes on writing at the new end.
    private func keepLogSmall(_ seat: UUID) async {
        let file = logFile(for: seat)
        while !Task.isCancelled {
            if let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int,
               size > timings.logLimitBytes {
                truncate(file.path, 0)
            }
            try? await Task.sleep(for: timings.logCheckEvery)
        }
    }

    /// Sends a report with a key of its own, kept for the transport's
    /// retries; a failure is logged and nothing else.
    private func send(
        _ operation: ContractOperation, seat: UUID, _ call: @Sendable (IdempotencyKey) async throws -> PlainOutcome
    ) async {
        do {
            _ = try await call(IdempotencyKey())
        } catch {
            log.warning("\(operation.rawValue) for seat \(seat.contractString) was not accepted")
        }
    }
}
