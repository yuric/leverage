import Foundation
import LeverageKit

/// One contract-draft job: the prompt, the tool run in a new empty folder,
/// and the contract (RD-37). A placeholder for WP14: it runs nothing and
/// answers no result.
struct DraftJob: Sendable {
    let context: FlowContext

    /// Runs the job `claim` carries.
    func run(_ claim: JobClaim, input: ContractDraftJobInput) async throws -> JobRunEnd { .noResult }
}
