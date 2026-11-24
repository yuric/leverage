import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// `AgentAPI` over HTTP, with the seat's token.
public struct AgentClient: AgentAPI {
    public let transport: HTTPTransport

    public init(transport: HTTPTransport) {
        self.transport = transport
    }

    public init(baseURL: URL, seatToken: String, session: URLSession = .shared) {
        transport = HTTPTransport(baseURL: baseURL, token: seatToken, session: session)
    }

    public func join(connection: LandingPromptConnection = .http) async throws -> JoinInstructions {
        let query = connection == .http ? [] : [URLQueryItem(name: "connection", value: connection.rawValue)]
        return try await transport.read(.getJoin, query: query)
    }

    public func next(wait: Int?) async throws -> NextItem {
        // Send the IF-14 default so the transport adds its timeout margin.
        try await transport.read(.getNext, waitSeconds: wait ?? 30)
    }

    public func command(key: IdempotencyKey) async throws -> PlainOutcome {
        try await transport.read(.getCommand, path: ["key": key.value])
    }

    public func claimNextTask(key: IdempotencyKey) async throws -> CommandOutcome<TaskClaim> {
        try await transport.command(.claimNextTask, key: key)
    }

    public func taskBriefing(taskID: UUID) async throws -> BriefingResponse {
        try await transport.read(.getTaskBriefing, path: ["id": taskID.contractString])
    }

    public func acknowledgeTaskBriefing(taskID: UUID, briefingHash: String, key: IdempotencyKey) async throws
        -> PlainOutcome {
        try await transport.command(
            .acknowledgeTaskBriefing, path: ["id": taskID.contractString],
            body: AcknowledgeBriefingRequest(briefingHash: briefingHash), key: key)
    }

    public func heartbeatTask(taskID: UUID, key: IdempotencyKey) async throws -> CommandOutcome<HeartbeatResult> {
        try await transport.command(.heartbeatTask, path: ["id": taskID.contractString], key: key)
    }

    public func startCriterion(taskID: UUID, criterionID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await transport.command(
            .startCriterion, path: ["id": taskID.contractString, "cid": criterionID.contractString], key: key)
    }

    public func passCriterion(taskID: UUID, criterionID: UUID, evidence: EvidenceInput, key: IdempotencyKey)
        async throws -> PlainOutcome {
        try await transport.command(
            .passCriterion, path: ["id": taskID.contractString, "cid": criterionID.contractString],
            body: PassCriterionRequest(evidence: evidence), key: key)
    }

    public func submitTask(taskID: UUID, _ request: SubmitTaskRequest, key: IdempotencyKey) async throws
        -> PlainOutcome {
        try await transport.command(.submitTask, path: ["id": taskID.contractString], body: request, key: key)
    }

    public func releaseTask(taskID: UUID, reason: ReleaseReason, key: IdempotencyKey) async throws -> PlainOutcome {
        try await transport.command(
            .releaseTask, path: ["id": taskID.contractString], body: ReleaseTaskRequest(reason: reason), key: key)
    }

    public func claimNextReview(key: IdempotencyKey) async throws -> CommandOutcome<ReviewClaim> {
        try await transport.command(.claimNextReview, key: key)
    }

    public func reviewBriefing(reviewID: UUID) async throws -> BriefingResponse {
        try await transport.read(.getReviewBriefing, path: ["id": reviewID.contractString])
    }

    public func acknowledgeReviewBriefing(reviewID: UUID, briefingHash: String, key: IdempotencyKey) async throws
        -> PlainOutcome {
        try await transport.command(
            .acknowledgeReviewBriefing, path: ["id": reviewID.contractString],
            body: AcknowledgeBriefingRequest(briefingHash: briefingHash), key: key)
    }

    public func heartbeatReview(reviewID: UUID, key: IdempotencyKey) async throws -> CommandOutcome<HeartbeatResult> {
        try await transport.command(.heartbeatReview, path: ["id": reviewID.contractString], key: key)
    }

    public func releaseReview(reviewID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await transport.command(.releaseReview, path: ["id": reviewID.contractString], key: key)
    }

    public func giveVerdict(reviewID: UUID, _ request: GiveVerdictRequest, key: IdempotencyKey) async throws
        -> PlainOutcome {
        try await transport.command(.giveVerdict, path: ["id": reviewID.contractString], body: request, key: key)
    }

    public func claimNextJob(key: IdempotencyKey) async throws -> CommandOutcome<JobClaim> {
        try await transport.command(.claimNextJob, key: key)
    }

    public func submitJobResult(jobID: UUID, _ request: JobResultRequest, key: IdempotencyKey) async throws
        -> PlainOutcome {
        try await transport.command(.submitJobResult, path: ["id": jobID.contractString], body: request, key: key)
    }
}


extension AgentClient {
    public func askQuestion(taskID: UUID, _ request: AskQuestionRequest, key: IdempotencyKey) async throws
        -> CommandOutcome<AskQuestionResult> {
        try await transport.command(.askQuestion, path: ["id": taskID.contractString], body: request, key: key)
    }

    public func getQuestion(taskID: UUID, questionID: UUID) async throws -> Question {
        try await transport.read(
            .getQuestion, path: ["id": taskID.contractString, "qid": questionID.contractString])
    }

    public func requestAccess(taskID: UUID, _ request: RequestAccessRequest, key: IdempotencyKey) async throws
        -> PlainOutcome {
        try await transport.command(.requestAccess, path: ["id": taskID.contractString], body: request, key: key)
    }

    public func reportCost(taskID: UUID, _ request: ReportCostRequest, key: IdempotencyKey) async throws
        -> PlainOutcome {
        try await transport.command(.reportCost, path: ["id": taskID.contractString], body: request, key: key)
    }

    public func startAction(taskID: UUID, actionID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await transport.command(
            .startAction, path: ["id": taskID.contractString, "aid": actionID.contractString],
            key: key)
    }

    public func reportActionDone(taskID: UUID, actionID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await transport.command(
            .reportActionDone, path: ["id": taskID.contractString, "aid": actionID.contractString],
            key: key)
    }
}
