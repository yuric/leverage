import Foundation
import LeverageKit

/// A planner's or an orchestrator's work on jobs: claim the next job, hand it
/// to its kind's file (`CheckJob`, `DraftJob`), submit the result once; a
/// claim that returns the job the seat already holds continues it (RD-40);
/// while the tool runs, `GET /v1/next` with no wait every 30 seconds, its
/// answer ignored, so that the seat keeps counting as polling (RD-15).
///
/// A job has no lease and nothing to give back: a stop ends the tool, and a
/// job with no result runs into its timeout on the server.
struct JobFlow: Sendable {
    let context: FlowContext

    /// Claims the next job and does it; nil when nothing was claimed, or the
    /// job is of a kind this milestone does not run.
    func claim() async throws -> FlowEnd? {
        let api = context.api
        guard case .completed(let claim?) = try await context.command("claim_next_job", {
            try await api.claimNextJob(key: $0)
        }) else { return nil }
        let job = claim.jobID.contractString
        context.log.info("claimed job \(job) (\(claim.kind.rawValue))")
        let ran: JobRunEnd
        switch claim.input {
        case .ruleCheck(let input):
            ran = try await whilePolling { try await CheckJob(context: context).run(claim, input: input) }
        case .contractDraft(let input):
            ran = try await whilePolling { try await DraftJob(context: context).run(claim, input: input) }
        case .other(let kind, _):
            // Questions and approvals are milestone 5's: never queued here.
            context.log.warning("job \(job): a \(kind.rawValue) job is not run by this runner")
            return nil
        }
        let end: FlowEnd
        switch ran {
        case .result(let result):
            end = try await submit(claim.jobID, result)
        case .noResult:
            end = .ended
        case .accountStopped(let report):
            context.state.accountStopped(report)
            end = .accountStopped(report)
        }
        context.log.info("job \(job): \(end.name)")
        return end
    }

    /// Sends the result once, with one key; a network failure resends it
    /// with the same key. A planner's contract may answer `pending` while an
    /// orchestrator checks it: the job is done, so that is not waited on.
    private func submit(_ jobID: UUID, _ result: JobResultRequest) async throws -> FlowEnd {
        let api = context.api
        let sent = try await context.command("submit_job_result") { key in
            let outcome = try await api.submitJobResult(jobID: jobID, result, key: key)
            guard outcome.outcome == .pending else { return outcome }
            return PlainOutcome.completed(nil, key: outcome.key, command: outcome.command)
        }
        switch sent {
        case .completed: return .finished
        // Refused (the job timed out, was withdrawn, or its task cancelled,
        // RD-41) or not readable: nothing more is sent for it.
        case .refused, .failed: return .ended
        }
    }

    /// Runs `work` while asking `GET /v1/next` with no wait every
    /// `jobPollInterval`; the asking ends when the work does.
    private func whilePolling(_ work: @escaping @Sendable () async throws -> JobRunEnd) async throws -> JobRunEnd {
        let api = context.api
        let timing = context.timing
        return try await withThrowingTaskGroup(of: JobRunEnd?.self) { group in
            group.addTask { try await work() }
            group.addTask {
                while true {
                    try await timing.pause(timing.jobPollInterval)
                    try Task.checkCancellation()
                    // Only the asking counts (it records the poll); the answer
                    // is ignored, and so is a failure: the next try comes.
                    _ = try? await api.next(wait: 0)
                }
            }
            defer { group.cancelAll() }
            while let finished = try await group.next() {
                if let finished { return finished }
            }
            throw CancellationError()
        }
    }
}
