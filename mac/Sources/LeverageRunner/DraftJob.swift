import Foundation
import LeverageKit

/// One contract-draft job: the prompt, one tool run in check mode in a new
/// empty folder, and the contract (RD-37). The tool only writes text: the
/// runner sends the contract, with the task's title and its three stored
/// values as the job's material gave them.
struct DraftJob: Sendable {
    let context: FlowContext

    /// Runs the job `claim` carries; the tool is ended 10 seconds before
    /// `claim.runDueAt` (RD-34). No contract, no result.
    func run(_ claim: JobClaim, input: ContractDraftJobInput) async throws -> JobRunEnd {
        guard let limit = CheckJob.timeLimit(runDueAt: claim.runDueAt, now: context.timing.now()),
              limit >= CheckJob.minimumRunSeconds else {
            context.log.info("job \(claim.jobID.contractString): no time left for a tool run")
            return .noResult
        }
        let nonce = JobPrompts.makeNonce()
        let prompt = JobPrompts.draft(material: input.material, nonce: nonce)
        switch try await JobToolRun.run(prompt, job: claim.jobID, timeLimit: limit, context: context) {
        case .answered(let answer):
            guard let contract = DraftParser.parse(answer.text, nonce: nonce, material: input.material) else {
                context.state.toolFailed()
                context.log.warning("job \(claim.jobID.contractString): no draft")
                return .noResult
            }
            context.state.toolAnswered()
            return .result(JobResultRequest(result: .contractDraft(contract), tokens: answer.tokens, spend: 0))
        case .failed(let failure):
            context.state.toolFailed()
            context.log.warning("job \(claim.jobID.contractString): \(failure)")
            return .noResult
        case .accountStopped(let report):
            return .accountStopped(report)
        }
    }
}
