import Foundation
import LeverageKit

/// An in-memory `AgentAPI` for the runner's tests. The test scripts the
/// answers it needs (`script { $0.next = { _ in NextItem(kind: .none) } }`);
/// every other call throws `FakeAPIError.notScripted`. Every call is
/// recorded, in order, in `calls`.
public final class FakeAgentAPI: AgentAPI, @unchecked Sendable {
    public typealias TaskCommand = @Sendable (UUID, IdempotencyKey) async throws -> PlainOutcome

    public struct Answers: Sendable {
        public var next: @Sendable (Int?) async throws -> NextItem = { _ in throw FakeAPIError.notScripted(.getNext) }
        public var command: @Sendable (IdempotencyKey) async throws -> PlainOutcome = { _ in
            throw FakeAPIError.notScripted(.getCommand)
        }
        public var claimNextTask: @Sendable (IdempotencyKey) async throws -> CommandOutcome<TaskClaim> = { _ in
            throw FakeAPIError.notScripted(.claimNextTask)
        }
        public var taskBriefing: @Sendable (UUID) async throws -> BriefingResponse = { _ in
            throw FakeAPIError.notScripted(.getTaskBriefing)
        }
        public var acknowledgeTaskBriefing: @Sendable (UUID, String, IdempotencyKey) async throws -> PlainOutcome = {
            _, _, _ in throw FakeAPIError.notScripted(.acknowledgeTaskBriefing)
        }
        public var heartbeatTask: @Sendable (UUID, IdempotencyKey) async throws -> CommandOutcome<HeartbeatResult> = {
            _, _ in throw FakeAPIError.notScripted(.heartbeatTask)
        }
        public var startCriterion: @Sendable (UUID, UUID, IdempotencyKey) async throws -> PlainOutcome = { _, _, _ in
            throw FakeAPIError.notScripted(.startCriterion)
        }
        public var passCriterion: @Sendable (UUID, UUID, EvidenceInput, IdempotencyKey) async throws -> PlainOutcome = {
            _, _, _, _ in throw FakeAPIError.notScripted(.passCriterion)
        }
        public var submitTask: @Sendable (UUID, SubmitTaskRequest, IdempotencyKey) async throws -> PlainOutcome = {
            _, _, _ in throw FakeAPIError.notScripted(.submitTask)
        }
        public var releaseTask: @Sendable (UUID, ReleaseReason, IdempotencyKey) async throws -> PlainOutcome = {
            _, _, _ in throw FakeAPIError.notScripted(.releaseTask)
        }
        public var claimNextReview: @Sendable (IdempotencyKey) async throws -> CommandOutcome<ReviewClaim> = { _ in
            throw FakeAPIError.notScripted(.claimNextReview)
        }
        public var reviewBriefing: @Sendable (UUID) async throws -> BriefingResponse = { _ in
            throw FakeAPIError.notScripted(.getReviewBriefing)
        }
        public var acknowledgeReviewBriefing: @Sendable (UUID, String, IdempotencyKey) async throws -> PlainOutcome = {
            _, _, _ in throw FakeAPIError.notScripted(.acknowledgeReviewBriefing)
        }
        public var heartbeatReview: @Sendable (UUID, IdempotencyKey) async throws -> CommandOutcome<HeartbeatResult> = {
            _, _ in throw FakeAPIError.notScripted(.heartbeatReview)
        }
        public var releaseReview: TaskCommand = { _, _ in throw FakeAPIError.notScripted(.releaseReview) }
        public var giveVerdict: @Sendable (UUID, GiveVerdictRequest, IdempotencyKey) async throws -> PlainOutcome = {
            _, _, _ in throw FakeAPIError.notScripted(.giveVerdict)
        }
        public var claimNextJob: @Sendable (IdempotencyKey) async throws -> CommandOutcome<JobClaim> = { _ in
            throw FakeAPIError.notScripted(.claimNextJob)
        }
        public var submitJobResult: @Sendable (UUID, JobResultRequest, IdempotencyKey) async throws -> PlainOutcome = {
            _, _, _ in throw FakeAPIError.notScripted(.submitJobResult)
        }

        public init() {}
    }

    private let state = FakeState(Answers())

    public init() {}

    public func script(_ change: (inout Answers) -> Void) { state.script(change) }
    public var calls: [FakeCall] { state.recorded }
    public func forgetCalls() { state.forget() }

    private func record(
        _ operation: ContractOperation, _ path: [String: String] = [:], key: IdempotencyKey? = nil,
        body: (any Encodable)? = nil
    ) -> Answers {
        state.record(FakeCall(operation, path: path, key: key, body: body.flatMap { FakeCall.json($0) }))
    }

    private static func id(_ uuid: UUID) -> [String: String] { ["id": uuid.contractString] }

    public func next(wait: Int?) async throws -> NextItem {
        try await record(.getNext).next(wait)
    }

    public func command(key: IdempotencyKey) async throws -> PlainOutcome {
        try await record(.getCommand, ["key": key.value]).command(key)
    }

    public func claimNextTask(key: IdempotencyKey) async throws -> CommandOutcome<TaskClaim> {
        try await record(.claimNextTask, key: key).claimNextTask(key)
    }

    public func taskBriefing(taskID: UUID) async throws -> BriefingResponse {
        try await record(.getTaskBriefing, Self.id(taskID)).taskBriefing(taskID)
    }

    public func acknowledgeTaskBriefing(taskID: UUID, briefingHash: String, key: IdempotencyKey) async throws
        -> PlainOutcome {
        try await record(
            .acknowledgeTaskBriefing, Self.id(taskID), key: key,
            body: AcknowledgeBriefingRequest(briefingHash: briefingHash)
        ).acknowledgeTaskBriefing(taskID, briefingHash, key)
    }

    public func heartbeatTask(taskID: UUID, key: IdempotencyKey) async throws -> CommandOutcome<HeartbeatResult> {
        try await record(.heartbeatTask, Self.id(taskID), key: key).heartbeatTask(taskID, key)
    }

    public func startCriterion(taskID: UUID, criterionID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await record(
            .startCriterion, ["id": taskID.contractString, "cid": criterionID.contractString], key: key
        ).startCriterion(taskID, criterionID, key)
    }

    public func passCriterion(taskID: UUID, criterionID: UUID, evidence: EvidenceInput, key: IdempotencyKey)
        async throws -> PlainOutcome {
        try await record(
            .passCriterion, ["id": taskID.contractString, "cid": criterionID.contractString], key: key,
            body: PassCriterionRequest(evidence: evidence)
        ).passCriterion(taskID, criterionID, evidence, key)
    }

    public func submitTask(taskID: UUID, _ request: SubmitTaskRequest, key: IdempotencyKey) async throws
        -> PlainOutcome {
        try await record(.submitTask, Self.id(taskID), key: key, body: request).submitTask(taskID, request, key)
    }

    public func releaseTask(taskID: UUID, reason: ReleaseReason, key: IdempotencyKey) async throws -> PlainOutcome {
        try await record(.releaseTask, Self.id(taskID), key: key, body: ReleaseTaskRequest(reason: reason))
            .releaseTask(taskID, reason, key)
    }

    public func claimNextReview(key: IdempotencyKey) async throws -> CommandOutcome<ReviewClaim> {
        try await record(.claimNextReview, key: key).claimNextReview(key)
    }

    public func reviewBriefing(reviewID: UUID) async throws -> BriefingResponse {
        try await record(.getReviewBriefing, Self.id(reviewID)).reviewBriefing(reviewID)
    }

    public func acknowledgeReviewBriefing(reviewID: UUID, briefingHash: String, key: IdempotencyKey) async throws
        -> PlainOutcome {
        try await record(
            .acknowledgeReviewBriefing, Self.id(reviewID), key: key,
            body: AcknowledgeBriefingRequest(briefingHash: briefingHash)
        ).acknowledgeReviewBriefing(reviewID, briefingHash, key)
    }

    public func heartbeatReview(reviewID: UUID, key: IdempotencyKey) async throws -> CommandOutcome<HeartbeatResult> {
        try await record(.heartbeatReview, Self.id(reviewID), key: key).heartbeatReview(reviewID, key)
    }

    public func releaseReview(reviewID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await record(.releaseReview, Self.id(reviewID), key: key).releaseReview(reviewID, key)
    }

    public func giveVerdict(reviewID: UUID, _ request: GiveVerdictRequest, key: IdempotencyKey) async throws
        -> PlainOutcome {
        try await record(.giveVerdict, Self.id(reviewID), key: key, body: request).giveVerdict(reviewID, request, key)
    }

    public func claimNextJob(key: IdempotencyKey) async throws -> CommandOutcome<JobClaim> {
        try await record(.claimNextJob, key: key).claimNextJob(key)
    }

    public func submitJobResult(jobID: UUID, _ request: JobResultRequest, key: IdempotencyKey) async throws
        -> PlainOutcome {
        try await record(.submitJobResult, Self.id(jobID), key: key, body: request)
            .submitJobResult(jobID, request, key)
    }
}
