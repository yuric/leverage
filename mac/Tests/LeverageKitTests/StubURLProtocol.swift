import Foundation

/// A stand-in for the network. Each test registers a canned answer for its own
/// host, so tests running in parallel never see each other's answers.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Answer: Sendable {
        var status: Int
        var body: Data
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var answers: [String: Answer] = [:]
    nonisolated(unsafe) private static var seen: [String: URLRequest] = [:]

    /// Returns a session whose requests to `host` get `answer`.
    static func session(host: String, answer: Answer) -> URLSession {
        lock.withLock { answers[host] = answer }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    /// The last request made to `host`, if any.
    static func lastRequest(host: String) -> URLRequest? {
        lock.withLock { seen[host] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = request.url?.host() ?? ""
        let answer = Self.lock.withLock { () -> Answer? in
            Self.seen[host] = request
            return Self.answers[host]
        }
        guard let answer, let url = request.url,
              let response = HTTPURLResponse(
                  url: url, statusCode: answer.status, httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": "application/json"])
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: answer.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
