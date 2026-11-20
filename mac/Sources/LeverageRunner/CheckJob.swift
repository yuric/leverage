import Foundation
import LeverageKit

/// What a job's run came to.
enum JobRunEnd: Equatable, Sendable {
    /// A result to submit, once.
    case result(JobResultRequest)
    /// No result: no verdict, or no draft, and no time left to ask again.
    /// Nothing is sent, and the job runs into its timeout (RD-31).
    case noResult
    /// The account stopped (a limit or a sign-out): nothing is submitted
    /// and the run ends with this report (HD-6, RD-40).
    case accountStopped(RunEndReport)
}

/// One rule-check job: the prompt, the tool run in check mode in a new empty
/// folder, the verdict, and the tokens and spend (RD-32, RD-33). One more
/// tool run if no verdict came and time is left, unless `allowsSecondRun` is
/// off. No result is sent without a verdict.
struct CheckJob: Sendable {
    let context: FlowContext
    /// False for the eval, which makes its own second try (RV-6).
    var allowsSecondRun = true

    /// How long before `run_due_at` the tool is ended (RD-34).
    static let endsBeforeDue: TimeInterval = 10
    /// The shortest time a tool run is started with: less is not enough for
    /// a tool to answer (the inventory's probes took 6 to 7 seconds), so the
    /// job is left to its timeout instead.
    static let minimumRunSeconds = 15

    /// Runs the job `claim` carries; the tool is ended 10 seconds before
    /// `claim.runDueAt` (RD-34).
    func run(_ claim: JobClaim, input: RuleCheckJobInput) async throws -> JobRunEnd {
        let material = input.material
        var tokens = 0
        for attempt in 1...(allowsSecondRun ? 2 : 1) {
            guard let limit = Self.timeLimit(runDueAt: claim.runDueAt, now: context.timing.now()),
                  limit >= Self.minimumRunSeconds else {
                context.log.info("job \(claim.jobID.contractString): no time left for a tool run")
                break
            }
            let nonce = JobPrompts.makeNonce()
            let prompt = JobPrompts.check(material: material, nonce: nonce)
            if let reason = JobToolRun.tooLong(prompt) {
                // The same material makes a prompt as long every time: no
                // second run is tried.
                context.state.toolFailed()
                context.log.warning("job \(claim.jobID.contractString): \(reason)")
                break
            }
            switch try await JobToolRun.run(prompt, job: claim.jobID, timeLimit: limit, context: context) {
            case .answered(let answer):
                tokens += answer.tokens
                if let verdict = VerdictParser.parse(
                    answer.text, nonce: nonce, mayAnswerNotApplicable: material.mayAnswerNotApplicable) {
                    context.state.toolAnswered()
                    // Spend is 0 for a login (RD-32, CL-11).
                    return .result(JobResultRequest(result: .ruleCheck(verdict), tokens: tokens, spend: 0))
                }
                context.state.toolFailed()
                context.log.warning("job \(claim.jobID.contractString), run \(attempt): no verdict")
            case .failed(let failure):
                context.state.toolFailed()
                context.log.warning("job \(claim.jobID.contractString), run \(attempt): \(failure)")
            case .accountStopped(let report):
                return .accountStopped(report)
            }
        }
        return .noResult
    }

    /// The whole seconds a tool run of the job may take at `now`: until 10
    /// seconds before `runDueAt`. Nil when less than one second is left.
    static func timeLimit(runDueAt: Date, now: Date) -> Int? {
        let left = (runDueAt.timeIntervalSince(now) - endsBeforeDue).rounded(.down)
        guard left >= 1, left.isFinite else { return nil }
        return Int(min(left, Double(Int32.max)))
    }
}

/// One tool run of a job, shared by `CheckJob` and `DraftJob`: in check mode
/// (read-only, the answering check's arguments) with the seat's model when
/// one is set, in a new empty folder made for the run and removed after it,
/// never the task's work folder (RD-33), under the job's time limit; a limit
/// or a sign-out names the job (RD-40).
enum JobToolRun {
    /// The most bytes of prompt a tool run is started with. A tool gets the
    /// prompt as one argument, and the Mac refuses to start a program whose
    /// arguments and environment pass `ARG_MAX` (1 MiB): a prompt over this
    /// limit would fail to start every time (milestone 4 review, finding 9).
    /// The server's limits on task text keep a contract well under it.
    static let promptByteLimit = 512 * 1024

    /// Why the prompt is not run, or nil when it fits.
    static func tooLong(_ prompt: String) -> String? {
        let bytes = prompt.utf8.count
        guard bytes > promptByteLimit else { return nil }
        return "the prompt is \(bytes) bytes, over the \(promptByteLimit) a tool's argument may hold"
    }

    static func run(_ prompt: String, job: UUID, timeLimit: Int, context: FlowContext) async throws
        -> Interruption.Result {
        if let reason = tooLong(prompt) { return .failed(.couldNotStart(reason)) }
        guard let folder = WorkFolder.makeJobFolder(workRoot: context.workRoot) else {
            return .failed(.couldNotStart("no folder for the job's run"))
        }
        defer { WorkFolder.removeJobFolder(folder) }
        let driver = context.driver
        let request = ToolRunRequest(
            prompt: prompt, folder: folder, purpose: .check, timeLimitSeconds: timeLimit, seatModel: true)
        return try await context.interruption.run(for: .job(job)) { try await driver.execute(request) }
    }
}
