import Foundation

/// A seat's calls, one method per served operation. The runner
/// takes `any AgentAPI`: `AgentClient` sends them over HTTP with the seat's
/// token, and LeverageTestSupport's `FakeAgentAPI` answers them in memory.
public protocol AgentAPI: Sendable {
    /// `get_join`: instructions for the selected connection.
    func join(connection: LandingPromptConnection) async throws -> JoinInstructions

    /// `get_next`: the first true item; with `wait`, a long poll.
    func next(wait: Int?) async throws -> NextItem
    /// `get_command`: a command's outcome by its key.
    func command(key: IdempotencyKey) async throws -> PlainOutcome

    // Building.

    /// `claim_next_task`.
    func claimNextTask(key: IdempotencyKey) async throws -> CommandOutcome<TaskClaim>
    /// `get_task_briefing`.
    func taskBriefing(taskID: UUID) async throws -> BriefingResponse
    /// `acknowledge_task_briefing`.
    func acknowledgeTaskBriefing(taskID: UUID, briefingHash: String, key: IdempotencyKey) async throws
        -> PlainOutcome
    /// `heartbeat_task`.
    func heartbeatTask(taskID: UUID, key: IdempotencyKey) async throws -> CommandOutcome<HeartbeatResult>
    /// `start_criterion`.
    func startCriterion(taskID: UUID, criterionID: UUID, key: IdempotencyKey) async throws -> PlainOutcome
    /// `pass_criterion`.
    func passCriterion(taskID: UUID, criterionID: UUID, evidence: EvidenceInput, key: IdempotencyKey)
        async throws -> PlainOutcome
    /// `submit_task`.
    func submitTask(taskID: UUID, _ request: SubmitTaskRequest, key: IdempotencyKey) async throws -> PlainOutcome
    /// `release_task`, with a reason a seat may choose.
    func releaseTask(taskID: UUID, reason: ReleaseReason, key: IdempotencyKey) async throws -> PlainOutcome

    // Reviewing.

    /// `claim_next_review`.
    func claimNextReview(key: IdempotencyKey) async throws -> CommandOutcome<ReviewClaim>
    /// `get_review_briefing`.
    func reviewBriefing(reviewID: UUID) async throws -> BriefingResponse
    /// `acknowledge_review_briefing`.
    func acknowledgeReviewBriefing(reviewID: UUID, briefingHash: String, key: IdempotencyKey) async throws
        -> PlainOutcome
    /// `heartbeat_review`.
    func heartbeatReview(reviewID: UUID, key: IdempotencyKey) async throws -> CommandOutcome<HeartbeatResult>
    /// `release_review`.
    func releaseReview(reviewID: UUID, key: IdempotencyKey) async throws -> PlainOutcome
    /// `give_verdict`.
    func giveVerdict(reviewID: UUID, _ request: GiveVerdictRequest, key: IdempotencyKey) async throws
        -> PlainOutcome

    // Jobs: a planner's contract drafts and an orchestrator's rule checks
    // (milestone 4).

    /// `claim_next_job`: the next job; a seat that already holds one gets
    /// that one again (RD-35, RD-40).
    func claimNextJob(key: IdempotencyKey) async throws -> CommandOutcome<JobClaim>
    /// `submit_job_result`: the result in the shape of the job's kind.
    func submitJobResult(jobID: UUID, _ request: JobResultRequest, key: IdempotencyKey) async throws
        -> PlainOutcome

    // Questions, access, cost and outward actions.

    /// `ask_question`.
    func askQuestion(taskID: UUID, _ request: AskQuestionRequest, key: IdempotencyKey) async throws
        -> CommandOutcome<AskQuestionResult>
    /// `get_question`.
    func getQuestion(taskID: UUID, questionID: UUID) async throws -> Question
    /// `request_access`.
    func requestAccess(taskID: UUID, _ request: RequestAccessRequest, key: IdempotencyKey) async throws
        -> PlainOutcome
    /// `report_cost`.
    func reportCost(taskID: UUID, _ request: ReportCostRequest, key: IdempotencyKey) async throws -> PlainOutcome
    /// `start_action`.
    func startAction(taskID: UUID, actionID: UUID, key: IdempotencyKey) async throws -> PlainOutcome
    /// `report_action_done`.
    func reportActionDone(taskID: UUID, actionID: UUID, key: IdempotencyKey) async throws -> PlainOutcome
}

extension AgentAPI {
    public func join() async throws -> JoinInstructions {
        try await join(connection: .http)
    }

    /// A conformer that has no server can leave join unsupported.
    public func join(connection: LandingPromptConnection) async throws -> JoinInstructions {
        throw LeverageClientError.unsupportedOperation(.getJoin)
    }
}
