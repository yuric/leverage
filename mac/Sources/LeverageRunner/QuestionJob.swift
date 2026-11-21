import Foundation
import LeverageKit

/// The work for a question claim. WP14 supplies the tool run.
struct QuestionJob: Sendable {
    let context: FlowContext

    func run(_ claim: JobClaim, input: QuestionJobInput) async throws -> JobRunEnd {
        .noResult
    }
}


// The offline eval has no server and refuses every agent call.
extension EvalRun.NoServer {
    func askQuestion(taskID: UUID, _ request: AskQuestionRequest, key: IdempotencyKey) async throws
        -> CommandOutcome<AskQuestionResult> {
        throw NotCalled()
    }

    func getQuestion(taskID: UUID, questionID: UUID) async throws -> Question {
        throw NotCalled()
    }

    func requestAccess(taskID: UUID, _ request: RequestAccessRequest, key: IdempotencyKey) async throws
        -> PlainOutcome {
        throw NotCalled()
    }

    func reportCost(taskID: UUID, _ request: ReportCostRequest, key: IdempotencyKey) async throws -> PlainOutcome {
        throw NotCalled()
    }

    func startAction(taskID: UUID, actionID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        throw NotCalled()
    }

    func reportActionDone(taskID: UUID, actionID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        throw NotCalled()
    }
}
