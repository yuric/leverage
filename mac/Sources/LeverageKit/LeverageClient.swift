import Foundation

/// The body of `GET /v1/health`.
public struct Health: Decodable, Equatable, Sendable {
    public let status: String
    public let version: String

    public init(status: String, version: String) {
        self.status = status
        self.version = version
    }
}

/// Every error the client raises itself. Transport failures pass through as
/// the `URLError` that `URLSession` threw.
public enum LeverageClientError: Error, Equatable, Sendable {
    /// The API answered with a status other than 200.
    case unexpectedStatus(Int)
    /// The API answered 200 with a body that is not the expected JSON.
    case invalidBody
    /// The answer was not an HTTP response.
    case notHTTP
}

/// A client of the leverage API.
public struct LeverageClient: Sendable {
    public let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    /// Reads `GET /v1/health`.
    public func health() async throws -> Health {
        var request = URLRequest(url: baseURL.appending(path: "v1/health"))
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LeverageClientError.notHTTP
        }
        guard http.statusCode == 200 else {
            throw LeverageClientError.unexpectedStatus(http.statusCode)
        }
        do {
            return try JSONDecoder().decode(Health.self, from: data)
        } catch {
            throw LeverageClientError.invalidBody
        }
    }
}
