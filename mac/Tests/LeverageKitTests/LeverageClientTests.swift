import Foundation
import Testing
@testable import LeverageKit

@Suite("LeverageClient.health()")
struct LeverageClientTests {
    private func client(host: String, status: Int, body: String) -> LeverageClient {
        let session = StubURLProtocol.session(
            host: host, answer: .init(status: status, body: Data(body.utf8)))
        return LeverageClient(baseURL: URL(string: "http://\(host):3000")!, session: session)
    }

    @Test("decodes a 200 answer and asks GET /v1/health")
    func success() async throws {
        let client = client(
            host: "success.test", status: 200,
            body: #"{"status":"ok","version":"1.2.3"}"#)

        let health = try await client.health()

        #expect(health == Health(status: "ok", version: "1.2.3"))
        let request = try #require(StubURLProtocol.lastRequest(host: "success.test"))
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "http://success.test:3000/v1/health")
    }

    @Test("keeps a path on the base URL")
    func basePath() async throws {
        let session = StubURLProtocol.session(
            host: "path.test",
            answer: .init(status: 200, body: Data(#"{"status":"ok","version":"1"}"#.utf8)))
        let client = LeverageClient(
            baseURL: URL(string: "http://path.test/leverage/")!, session: session)

        _ = try await client.health()

        let request = try #require(StubURLProtocol.lastRequest(host: "path.test"))
        #expect(request.url?.absoluteString == "http://path.test/leverage/v1/health")
    }

    @Test("throws unexpectedStatus for a non-200 answer")
    func nonOK() async {
        let client = client(
            host: "error.test", status: 503,
            body: #"{"error":{"code":"unavailable","message":"down"}}"#)

        await #expect(throws: LeverageClientError.unexpectedStatus(503)) {
            try await client.health()
        }
    }

    @Test("throws invalidBody for JSON it cannot decode")
    func badJSON() async {
        let client = client(host: "badjson.test", status: 200, body: "not json")

        await #expect(throws: LeverageClientError.invalidBody) {
            try await client.health()
        }
    }
}
