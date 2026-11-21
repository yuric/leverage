import Foundation
import LeverageKit

/// An in-memory `HelperAPI` for the helper's tests. The test scripts the
/// answers it needs (`script { $0.next = { _ in HelperNext(request: nil) } }`);
/// every other call throws `FakeAPIError.notScripted`. Every call is
/// recorded, in order, in `calls`.
public final class FakeHelperAPI: HelperAPI, @unchecked Sendable {
    public struct Answers: Sendable {
        public var next: @Sendable (Int?) async throws -> HelperNext = { _ in
            throw FakeAPIError.notScripted(.getHelperNext)
        }
        public var reportRequestProgress: @Sendable (UUID, HelperCheckProgress, IdempotencyKey) async throws
            -> PlainOutcome = { _, _, _ in throw FakeAPIError.notScripted(.reportRequestProgress) }
        public var reportRequestResult: @Sendable (UUID, HelperRequestResult, IdempotencyKey) async throws
            -> PlainOutcome = { _, _, _ in throw FakeAPIError.notScripted(.reportRequestResult) }
        public var issueSeatToken: @Sendable (UUID, IdempotencyKey) async throws
            -> CommandOutcome<SeatTokenPickupAnswer> = { _, _ in throw FakeAPIError.notScripted(.issueSeatToken) }
        public var reportRunStarted: @Sendable (UUID, RunStartedReport, IdempotencyKey) async throws
            -> PlainOutcome = { _, _, _ in throw FakeAPIError.notScripted(.reportRunStarted) }
        public var reportRunStopped: @Sendable (UUID, RunStoppedReport, IdempotencyKey) async throws
            -> PlainOutcome = { _, _, _ in throw FakeAPIError.notScripted(.reportRunStopped) }
        public var reportReading: @Sendable (UUID, CredentialReading, IdempotencyKey) async throws
            -> PlainOutcome = { _, _, _ in throw FakeAPIError.notScripted(.reportReading) }
        public var reportLimit: @Sendable (UUID, LimitReport, IdempotencyKey) async throws
            -> PlainOutcome = { _, _, _ in throw FakeAPIError.notScripted(.reportLimit) }
        public var reportSignedOut: @Sendable (UUID, SignOutReport, IdempotencyKey) async throws
            -> PlainOutcome = { _, _, _ in throw FakeAPIError.notScripted(.reportSignedOut) }

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

    public func next(wait: Int?) async throws -> HelperNext {
        try await record(.getHelperNext).next(wait)
    }

    public func reportRequestProgress(requestID: UUID, _ progress: HelperCheckProgress, key: IdempotencyKey)
        async throws -> PlainOutcome {
        try await record(.reportRequestProgress, Self.id(requestID), key: key, body: progress)
            .reportRequestProgress(requestID, progress, key)
    }

    public func reportRequestResult(requestID: UUID, _ result: HelperRequestResult, key: IdempotencyKey)
        async throws -> PlainOutcome {
        try await record(
            .reportRequestResult, Self.id(requestID), key: key, body: ReportRequestResultRequest(result: result)
        ).reportRequestResult(requestID, result, key)
    }

    public func issueSeatToken(requestID: UUID, key: IdempotencyKey) async throws
        -> CommandOutcome<SeatTokenPickupAnswer> {
        try await record(.issueSeatToken, Self.id(requestID), key: key).issueSeatToken(requestID, key)
    }

    public func reportRunStarted(seatID: UUID, _ report: RunStartedReport, key: IdempotencyKey) async throws
        -> PlainOutcome {
        try await record(.reportRunStarted, Self.id(seatID), key: key, body: report)
            .reportRunStarted(seatID, report, key)
    }

    public func reportRunStopped(seatID: UUID, _ report: RunStoppedReport, key: IdempotencyKey) async throws
        -> PlainOutcome {
        try await record(.reportRunStopped, Self.id(seatID), key: key, body: report)
            .reportRunStopped(seatID, report, key)
    }

    public func reportReading(credentialID: UUID, _ reading: CredentialReading, key: IdempotencyKey)
        async throws -> PlainOutcome {
        try await record(.reportReading, Self.id(credentialID), key: key, body: reading)
            .reportReading(credentialID, reading, key)
    }

    public func reportLimit(credentialID: UUID, _ report: LimitReport, key: IdempotencyKey) async throws
        -> PlainOutcome {
        try await record(.reportLimit, Self.id(credentialID), key: key, body: report)
            .reportLimit(credentialID, report, key)
    }

    public func reportSignedOut(credentialID: UUID, _ report: SignOutReport, key: IdempotencyKey) async throws
        -> PlainOutcome {
        try await record(.reportSignedOut, Self.id(credentialID), key: key, body: report)
            .reportSignedOut(credentialID, report, key)
    }
}
