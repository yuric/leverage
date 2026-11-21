import Foundation
import LeverageKit

/// Judges one outward action in check mode, or passes it to the owner.
struct ApprovalJob: Sendable {
    let context: FlowContext
    /// The eval schedules its own retry and needs to distinguish a missing decision.
    var allowsSecondRun = true

    func run(_ claim: JobClaim, input: ApprovalJobInput) async throws -> JobRunEnd {
        let fallback = ApprovalJobResult(decision: .passToOwner, reason: "The agent gave no decision.")
        return try await JobToolRun.runForResult(
            claim, context: context, attempts: allowsSecondRun ? 2 : 1,
            fallback: allowsSecondRun ? .approval(fallback) : nil,
            prompt: { JobPrompts.approval(material: input.material, nonce: $0) },
            parse: { DecisionParser.parse($0, nonce: $1).map(JobResult.approval) })
    }
}
