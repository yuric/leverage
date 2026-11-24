import Foundation

/// The helper's calls, one method per served operation. The
/// helper takes `any HelperAPI`: `HelperClient` sends them over HTTP with
/// the helper's token, and LeverageTestSupport's `FakeHelperAPI` answers
/// them in memory.
public protocol HelperAPI: Sendable {
    /// `get_helper_next`: the next request; with `wait`, a long poll.
    func next(wait: Int?) async throws -> HelperNext
    /// `report_request_progress`: one check's state while a request runs.
    func reportRequestProgress(requestID: UUID, _ progress: HelperCheckProgress, key: IdempotencyKey)
        async throws -> PlainOutcome
    /// `report_request_result`.
    func reportRequestResult(requestID: UUID, _ result: HelperRequestResult, key: IdempotencyKey) async throws
        -> PlainOutcome
    /// `issue_seat_token`: a fresh token for the seat of a `start_seat`
    /// request; a repeated answer carries none, so ask again with a new key.
    func issueSeatToken(requestID: UUID, key: IdempotencyKey) async throws -> CommandOutcome<SeatTokenPickupAnswer>
    /// `report_run_started`.
    func reportRunStarted(seatID: UUID, _ report: RunStartedReport, key: IdempotencyKey) async throws
        -> PlainOutcome
    /// `report_run_stopped`.
    func reportRunStopped(seatID: UUID, _ report: RunStoppedReport, key: IdempotencyKey) async throws
        -> PlainOutcome
    /// `report_limit`: a run of this credential's account hit a limit (HD-10).
    /// The answer carries no result (HE-8).
    func reportLimit(credentialID: UUID, _ report: LimitReport, key: IdempotencyKey) async throws -> PlainOutcome
    /// `report_signed_out`: a run found this credential's login signed out.
    func reportSignedOut(credentialID: UUID, _ report: SignOutReport, key: IdempotencyKey) async throws
        -> PlainOutcome
    /// `report_reading`: a usage reading, with figures and times only.
    func reportReading(credentialID: UUID, _ reading: CredentialReading, key: IdempotencyKey) async throws
        -> PlainOutcome
}
