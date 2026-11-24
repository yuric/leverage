import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The body of `GET /v1/health`.
public struct Health: Codable, Equatable, Sendable {
    public let status: String
    public let version: String

    public init(status: String, version: String) {
        self.status = status
        self.version = version
    }
}

/// Every error the clients raise themselves, besides a `TransportError`
/// (the API's 400, 401, 404 and 422). Network failures pass through as the
/// `URLError` that `URLSession` threw.
public enum LeverageClientError: Error, Equatable, Sendable {
    /// The API answered with a status the operation does not have.
    case unexpectedStatus(Int)
    /// The API answered with a body that is not the operation's JSON.
    case invalidBody
    /// The answer was not an HTTP response.
    case notHTTP
    /// The API refused the request (409).
    case refused(Refusal)
    /// A command is pending (202) where its result was asked for.
    case pending(CommandName)
    /// An operation's path needs this parameter, and it was not given.
    case missingPathParameter(String)
    /// This API client has no implementation of the operation.
    case unsupportedOperation(ContractOperation)
    /// The value is not an idempotency key.
    case invalidKey(String)
}

/// The infrastructure client: the public health check.
public struct LeverageClient: Sendable {
    public let baseURL: URL
    private let transport: HTTPTransport

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        transport = HTTPTransport(baseURL: baseURL, session: session)
    }

    /// Reads `GET /v1/health` (`get_health`).
    public func health() async throws -> Health {
        try await transport.read(.getHealth, signedIn: false)
    }
}
