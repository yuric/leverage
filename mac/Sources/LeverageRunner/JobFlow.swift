import Foundation
import LeverageKit

/// A planner's or an orchestrator's work on jobs: claim the next job, hand it
/// to its kind's file, submit the result once; a
/// claim that returns the job the seat already holds continues it (RD-40);
/// while the tool runs, `GET /v1/next` with no wait every 30 seconds, its
/// answer ignored, so that the seat keeps counting as polling (RD-15).
///
/// A job has no lease and nothing to give back: a stop ends the tool, and a
/// job with no result runs into its timeout on the server.
struct JobFlow: Sendable {
    let context: FlowContext

    /// Claims the next job and does it. Returns nil when there is no claim
    /// or its input cannot be read.
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
            if let input = claim.input.questionInput {
                ran = try await whilePolling { try await QuestionJob(context: context).run(claim, input: input) }
            } else if let input = claim.input.approvalInput {
                ran = try await whilePolling { try await ApprovalJob(context: context).run(claim, input: input) }
            } else {
                context.log.warning("job \(job): unreadable \(kind.rawValue) input")
                return nil
            }
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

extension JobToolRun {
    /// The question and approval jobs share the check run's deadline, mode
    /// and account handling. Each attempt has a fresh nonce. Report usage
    /// for all attempts, including those whose answer could not be read.
    static func runForResult(
        _ claim: JobClaim, context: FlowContext, attempts: Int, fallback: JobResult?,
        prompt: (String) -> String, parse: (String, String) -> JobResult?
    ) async throws -> JobRunEnd {
        let job = claim.jobID.contractString
        // Each tool invocation uses one of the job's attempts, even on a
        // short rate limit, so a retry always makes a new prompt and nonce.
        let runContext = FlowContext(
            api: context.api, driver: context.driver, timing: context.timing, log: context.log,
            state: context.state, workRoot: context.workRoot, home: context.home,
            interruption: context.interruption.withoutInPlaceRetries)
        var tokens = 0
        for attempt in 1...attempts {
            try Task.checkCancellation()
            guard let limit = CheckJob.timeLimit(runDueAt: claim.runDueAt, now: context.timing.now()),
                  limit >= CheckJob.minimumRunSeconds else {
                context.log.info("job \(job): no time left for a tool run")
                if attempt == 1 { return .noResult }
                break
            }
            let nonce = JobPrompts.makeNonce()
            let framed = prompt(nonce)
            if let reason = tooLong(framed) {
                context.state.toolFailed()
                context.log.warning("job \(job): \(reason)")
                return .noResult
            }
            switch try await run(framed, job: claim.jobID, timeLimit: limit, context: runContext) {
            case .answered(let answer):
                tokens += answer.tokens
                if let result = parse(answer.text, nonce) {
                    context.state.toolAnswered()
                    return .result(JobResultRequest(result: result, tokens: tokens, spend: 0))
                }
                context.state.toolFailed()
                context.log.warning("job \(job), run \(attempt): no result marker")
            case .failed(let failure):
                context.state.toolFailed()
                context.log.warning("job \(job), run \(attempt): \(failure)")
            case .accountStopped(let report):
                return .accountStopped(report)
            }
        }
        try Task.checkCancellation()
        guard let fallback else { return .noResult }
        return .result(JobResultRequest(result: fallback, tokens: tokens, spend: 0))
    }
}

extension Interruption {
    /// Keeps limit and sign-out detection, with one invocation per attempt.
    var withoutInPlaceRetries: Interruption {
        Interruption(provider: provider, hasCredential: hasCredential, waits: [], signInStatus: signInStatus, log: log)
    }
}
