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
/// off. A placeholder for WP14: it runs nothing and answers no result.
struct CheckJob: Sendable {
    let context: FlowContext
    /// False for the eval, which makes its own second try (RV-6).
    var allowsSecondRun = true

    /// Runs the job `claim` carries; the tool is ended 10 seconds before
    /// `claim.runDueAt` (RD-34).
    func run(_ claim: JobClaim, input: RuleCheckJobInput) async throws -> JobRunEnd { .noResult }
}
