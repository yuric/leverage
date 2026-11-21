import Foundation
import LeverageKit

/// The work for an approval claim. WP14 supplies the tool run.
struct ApprovalJob: Sendable {
    let context: FlowContext
    var allowsSecondRun = true

    func run(_ claim: JobClaim, input: ApprovalJobInput) async throws -> JobRunEnd {
        .noResult
    }
}
