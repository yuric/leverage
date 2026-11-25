import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// `HelperAPI` over HTTP, with the helper's token.
public struct HelperClient: HelperAPI {
    public let transport: HTTPTransport

    public init(transport: HTTPTransport) {
        self.transport = transport
    }

    public init(baseURL: URL, helperToken: String, session: URLSession = HTTPTransport.uncachedSession) {
        transport = HTTPTransport(baseURL: baseURL, token: helperToken, session: session)
    }

    public func next(wait: Int?) async throws -> HelperNext {
        // The helper's next call (IF-15) shares the IF-14 wait default.
        try await transport.read(.getHelperNext, waitSeconds: wait ?? 30)
    }

    public func reportRequestProgress(requestID: UUID, _ progress: HelperCheckProgress, key: IdempotencyKey)
        async throws -> PlainOutcome {
        try await transport.command(
            .reportRequestProgress, path: ["id": requestID.contractString], body: progress, key: key)
    }

    public func reportRequestResult(requestID: UUID, _ result: HelperRequestResult, key: IdempotencyKey)
        async throws -> PlainOutcome {
        try await transport.command(
            .reportRequestResult, path: ["id": requestID.contractString],
            body: ReportRequestResultRequest(result: result), key: key)
    }

    public func issueSeatToken(requestID: UUID, key: IdempotencyKey) async throws
        -> CommandOutcome<SeatTokenPickupAnswer> {
        try await transport.command(.issueSeatToken, path: ["id": requestID.contractString], key: key)
    }

    public func reportRunStarted(seatID: UUID, _ report: RunStartedReport, key: IdempotencyKey) async throws
        -> PlainOutcome {
        try await transport.command(.reportRunStarted, path: ["id": seatID.contractString], body: report, key: key)
    }

    public func reportRunStopped(seatID: UUID, _ report: RunStoppedReport, key: IdempotencyKey) async throws
        -> PlainOutcome {
        try await transport.command(.reportRunStopped, path: ["id": seatID.contractString], body: report, key: key)
    }

    public func reportLimit(credentialID: UUID, _ report: LimitReport, key: IdempotencyKey) async throws
        -> PlainOutcome {
        try await transport.command(.reportLimit, path: ["id": credentialID.contractString], body: report, key: key)
    }

    public func reportSignedOut(credentialID: UUID, _ report: SignOutReport, key: IdempotencyKey) async throws
        -> PlainOutcome {
        try await transport.command(
            .reportSignedOut, path: ["id": credentialID.contractString], body: report, key: key)
    }

    public func reportReading(credentialID: UUID, _ reading: CredentialReading, key: IdempotencyKey) async throws
        -> PlainOutcome {
        try await transport.command(
            .reportReading, path: ["id": credentialID.contractString], body: reading, key: key)
    }
}
