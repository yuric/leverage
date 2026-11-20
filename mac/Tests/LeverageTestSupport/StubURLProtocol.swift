import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A stand-in for the network. Each test registers the answers for its own
/// host, so tests running in parallel never see each other's answers or
/// requests. A host answers with one fixed answer, with a list of answers in
/// order (the last one repeats), or with a function of the request.
public final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    public struct Answer: Sendable {
        public var status: Int
        public var body: Data
        /// When set, the request fails with this error instead of answering.
        public var failure: URLError.Code?

        public init(status: Int, body: Data) {
            self.status = status
            self.body = body
            self.failure = nil
        }

        public init(status: Int, json: String) {
            self.init(status: status, body: Data(json.utf8))
        }

        /// The request fails as if the network did, with `code`.
        public static func failure(_ code: URLError.Code) -> Answer {
            var answer = Answer(status: 0, body: Data())
            answer.failure = code
            return answer
        }
    }

    /// A request as the stub saw it, with its body read from the stream
    /// `URLSession` turns it into.
    public struct Recorded: Sendable {
        public let request: URLRequest
        public let body: Data?

        public var method: String? { request.httpMethod }
        public var url: URL? { request.url }
        public func header(_ name: String) -> String? { request.value(forHTTPHeaderField: name) }
    }

    private enum Script {
        case answers([Answer])
        case respond(@Sendable (URLRequest, Data?) -> Answer)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var scripts: [String: Script] = [:]
    nonisolated(unsafe) private static var seen: [String: [Recorded]] = [:]

    /// Returns a session whose requests to `host` get `answer`.
    public static func session(host: String, answer: Answer) -> URLSession {
        session(host: host, answers: [answer])
    }

    /// Returns a session whose requests to `host` get `answers` in order;
    /// the last one answers every request after it.
    public static func session(host: String, answers: [Answer]) -> URLSession {
        precondition(!answers.isEmpty, "give at least one answer")
        return install(host: host, script: .answers(answers))
    }

    /// Returns a session whose requests to `host` are answered by `respond`,
    /// given the request and its body.
    public static func session(
        host: String, respond: @escaping @Sendable (URLRequest, Data?) -> Answer
    ) -> URLSession {
        install(host: host, script: .respond(respond))
    }

    /// The last request made to `host`, if any.
    public static func lastRequest(host: String) -> URLRequest? {
        lock.withLock { seen[host]?.last?.request }
    }

    /// Every request made to `host`, in order.
    public static func requests(host: String) -> [Recorded] {
        lock.withLock { seen[host] ?? [] }
    }

    private static func install(host: String, script: Script) -> URLSession {
        lock.withLock {
            scripts[host] = script
            seen[host] = []
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override public class func canInit(with request: URLRequest) -> Bool { true }

    override public class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override public func startLoading() {
        let host = request.url?.host() ?? ""
        let body = request.httpBody ?? Self.read(request.httpBodyStream)
        let recorded = Recorded(request: request, body: body)
        let (script, index) = Self.lock.withLock { () -> (Script?, Int) in
            Self.seen[host, default: []].append(recorded)
            return (Self.scripts[host], Self.seen[host, default: []].count - 1)
        }
        let answer: Answer?
        switch script {
        case .answers(let answers):
            answer = answers[min(index, answers.count - 1)]
        case .respond(let respond):
            answer = respond(request, body)
        case nil:
            answer = nil
        }
        guard let answer, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        if let failure = answer.failure {
            client?.urlProtocol(self, didFailWithError: URLError(failure))
            return
        }
        guard let response = HTTPURLResponse(
            url: url, statusCode: answer.status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: answer.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override public func stopLoading() {}

    private static func read(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
