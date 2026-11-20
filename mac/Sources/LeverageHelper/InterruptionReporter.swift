import Foundation
import LeverageKit

/// Turns what a runner reported when its account stopped into the helper's
/// report to the server (plan §2.2, HD-10): `report_limit` for a limit,
/// `report_signed_out` for a sign-out, and nothing else. The report keeps
/// one key, which every send repeats while the network or the server fails.
/// A refusal, or any other answer the server gave, is logged with its code
/// and followed by one `report_run_stopped` with the reason `limit` or
/// `signed_out`, so the server still records the run as ended.
///
/// The helper never sees the tool's output: it has only the `RunEndReport`,
/// which holds none of it (HD-6).
struct InterruptionReporter: Sendable {
    /// What became of one report.
    enum Result: Equatable, Sendable {
        /// The server accepted the limit or sign-out report.
        case reported
        /// The server refused it; the run's end was reported as stopped.
        case refusedThenStopped
        /// The line cannot be made into a report: it names no task and no
        /// review (the report needs exactly one), or it is a limit with no
        /// window (HE-32). The run's end was reported as stopped.
        case unreportableThenStopped
        /// Nothing was accepted: every send failed, or the helper stopped.
        case notSent
    }

    let api: any HelperAPI
    let timings: HelperTimings
    let log: Log

    init(api: any HelperAPI, timings: HelperTimings, log: Log) {
        self.api = api
        self.timings = timings
        self.log = log
    }

    /// Reports the end of the run of `seatID` on `credentialID`.
    /// `toolVersion` is the version the helper found when it started the
    /// run, sent when the line has none.
    func report(_ end: RunEndReport, seatID: UUID, credentialID: UUID, toolVersion: String?) async -> Result {
        let reason: RunStopReason = end.kind == .limit ? .limit : .signedOut
        let work: InterruptedWork
        if let task = end.taskID {
            work = .task(task)
        } else if let review = end.reviewID {
            work = .review(review)
        } else {
            log.warning("the run of seat \(seatID.contractString) ended (\(reason.rawValue)) holding no work")
            return await runStopped(seatID: seatID, credentialID: credentialID, reason: reason)
                ? .unreportableThenStopped : .notSent
        }
        let version = [end.toolVersion, toolVersion].compactMap { $0 }.first { !$0.isEmpty } ?? "unknown"

        let operation: ContractOperation
        let call: @Sendable (IdempotencyKey) async throws -> PlainOutcome
        switch end.kind {
        case .limit:
            guard let window = end.window else {
                // A line read from the runner always has one; a report made
                // in the helper might not.
                log.warning("the run of seat \(seatID.contractString) ended at a limit with no window")
                return await runStopped(seatID: seatID, credentialID: credentialID, reason: reason)
                    ? .unreportableThenStopped : .notSent
            }
            operation = .reportLimit
            let report = LimitReport(
                credentialID: credentialID, seatID: seatID, work: work, window: window,
                resetAt: end.resetAt, observedAt: end.observedAt, toolVersion: version)
            call = { key in try await api.reportLimit(credentialID: credentialID, report, key: key) }
        case .signedOut:
            operation = .reportSignedOut
            let report = SignOutReport(
                credentialID: credentialID, seatID: seatID, work: work, observedAt: end.observedAt,
                toolVersion: version)
            call = { key in try await api.reportSignedOut(credentialID: credentialID, report, key: key) }
        }

        switch await send(operation, call) {
        case .accepted:
            log.info("\(operation.rawValue) for seat \(seatID.contractString) was accepted")
            return .reported
        case .answered(let code):
            log.warning("\(operation.rawValue) for seat \(seatID.contractString) was not accepted: \(code)")
            return await runStopped(seatID: seatID, credentialID: credentialID, reason: reason)
                ? .refusedThenStopped : .notSent
        case .unsent:
            log.warning("\(operation.rawValue) for seat \(seatID.contractString) could not be sent")
            return .notSent
        }
    }

    /// `report_run_stopped` with the reason the runner gave.
    private func runStopped(seatID: UUID, credentialID: UUID, reason: RunStopReason) async -> Bool {
        let report = RunStoppedReport(credentialID: credentialID, observedAt: Date(), stopReason: reason)
        switch await send(.reportRunStopped, { key in
            try await api.reportRunStopped(seatID: seatID, report, key: key)
        }) {
        case .accepted:
            return true
        case .answered(let code):
            log.warning("report_run_stopped for seat \(seatID.contractString) was not accepted: \(code)")
            return false
        case .unsent:
            log.warning("report_run_stopped for seat \(seatID.contractString) could not be sent")
            return false
        }
    }

    private enum Sent {
        case accepted
        /// The server answered and refused, by a refusal or a 4xx; the
        /// code, never a body.
        case answered(String)
        case unsent
    }

    /// Sends under one key, again with the same key while the network or
    /// the server fails, pausing at most 2 seconds between sends (CL-31),
    /// as `RequestLoop` sends a request's result.
    private func send(
        _ operation: ContractOperation, _ call: @Sendable (IdempotencyKey) async throws -> PlainOutcome
    ) async -> Sent {
        let key = IdempotencyKey()
        var pause = timings.pauseAfterError
        for attempt in 1...RequestLoop.reportAttempts {
            do {
                let outcome = try await call(key)
                if outcome.outcome == .refused {
                    return .answered(outcome.refusal?.code.rawValue ?? "refused")
                }
                // Completed, or pending (taken and still running): accepted.
                return .accepted
            } catch {
                guard RequestLoop.isWorthSendingAgain(error) else { return .answered(Self.code(of: error)) }
                if Task.isCancelled || attempt == RequestLoop.reportAttempts { return .unsent }
                try? await Task.sleep(for: pause)
                pause = min(pause * 2, .seconds(2))
            }
        }
        return .unsent
    }

    /// A short name for an error the server gave; never its message.
    private static func code(of error: any Error) -> String {
        if let transport = error as? TransportError { return transport.code.rawValue }
        if case LeverageClientError.refused(let refusal)? = error as? LeverageClientError {
            return refusal.code.rawValue
        }
        if case LeverageClientError.unexpectedStatus(let status)? = error as? LeverageClientError {
            return "status \(status)"
        }
        return "\(type(of: error))"
    }
}
