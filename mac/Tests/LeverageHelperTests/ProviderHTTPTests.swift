import Foundation
import LeverageKit
import LeverageTestSupport
import Testing
@testable import LeverageHelper

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@Suite("Provider HTTP", .serialized)
struct ProviderHTTPTests {
    private static let token = "pretend-LVRG-TOKEN-a1b2c3d4e5f6-unit-test"
    private static let executable = URL(fileURLWithPath: "/tmp/build/LeverageHelper")
    private static let loopback = "http://127.0.0.1:48152"
    private let timeout = Patience.scaled(.seconds(30))

    @Test("each provider gets its one catalog GET and token header over HTTPS", arguments: [
        Route(.claudeApi, "https://api.anthropic.com/v1/models"),
        Route(.openaiApi, "https://api.openai.com/v1/models"),
        Route(.geminiApi, "https://generativelanguage.googleapis.com/v1beta/models", header: "x-goog-api-key"),
        Route(.grokApi, "https://api.x.ai/v1/api-key"),
        Route(.openrouter, "https://openrouter.ai/api/v1/key"),
    ])
    func catalogRoute(_ route: Route) async throws {
        TestProviderProtocol.prepare(.response())
        let response = try await transport().get(route.provider, token: Self.token, timeout: timeout)
        let requests = TestProviderProtocol.requests
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.url?.absoluteString == route.address)
        #expect(request.httpMethod == "GET")
        #expect(request.httpBody == nil)
        let header = request.value(forHTTPHeaderField: route.header)
        let expected = route.header == "Authorization" ? "Bearer \(Self.token)" : Self.token
        let tokenMatches = header == expected
        #expect(tokenMatches)
        let other = route.header == "Authorization" ? "x-goog-api-key" : "Authorization"
        #expect(request.value(forHTTPHeaderField: other) == nil)
        #expect(request.value(forHTTPHeaderField: "x-api-key") == nil)
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == (
            route.provider == .claudeApi ? "2026-10-21" : nil))
        #expect(response.status == 200)
    }

    @Test("the reply contains only this provider's named headers, with status and body", arguments: [
        Provider.claudeApi, .openaiApi, .geminiApi, .grokApi, .openrouter,
    ])
    func namedHeaders(_ provider: Provider) async throws {
        let body = Data(#"{"reply":"made up"}"#.utf8)
        TestProviderProtocol.prepare(.response(status: 403, headers: [
            "Anthropic-RateLimit-Requests-Remaining": "4",
            "X-RateLimit-Remaining-Requests": "7",
            "Set-Cookie": "test=made-up; Path=/",
            "X-Extra": Self.token,
        ], chunks: [body]))
        let response = try await transport().get(provider, token: Self.token, timeout: timeout)
        let expected: [String: String]
        switch provider {
        case .claudeApi: expected = ["anthropic-ratelimit-requests-remaining": "4"]
        case .openaiApi: expected = ["x-ratelimit-remaining-requests": "7"]
        default: expected = [:]
        }
        #expect(response.status == 403)
        #expect(response.body == body)
        let headersMatch = response.headers == expected
        #expect(headersMatch)
    }

    @Test("provider replies are neither cached nor used to set cookies")
    func noCacheOrCookie() async throws {
        TestProviderProtocol.prepare(.response(headers: [
            "Cache-Control": "max-age=3600",
            "Set-Cookie": "test=made-up; Secure; Path=/",
        ]))
        let http = try transport()
        for _ in 0..<2 {
            _ = try await http.get(.openaiApi, token: Self.token, timeout: timeout)
        }
        let requests = TestProviderProtocol.requests
        #expect(requests.count == 2)
        for request in requests {
            #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
            #expect(!request.httpShouldHandleCookies)
            #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        }
    }

    @Test("an oversized streamed body is refused before its end, and the limit itself fits")
    func bodyLimit() async throws {
        let half = Data(repeating: 0x61, count: 1 << 19)
        TestProviderProtocol.prepare(.response(chunks: [half, half]))
        let http = try transport()
        let atLimit = try await http.get(.openrouter, token: Self.token, timeout: timeout)
        #expect(atLimit.body.count == 1 << 20)

        TestProviderProtocol.prepare(.response(chunks: [half, half, Data([0x61])], finish: false))
        await #expect(throws: ProviderHTTP.Failure(host: "openrouter.ai", code: .bodyTooLarge)) {
            _ = try await http.get(.openrouter, token: Self.token, timeout: .seconds(2))
        }
        #expect(TestProviderProtocol.requests.count == 1)
    }

    @Test("a non-loopback or non-HTTP override is refused at startup", arguments: [
        "http://example.invalid:48152", "http://localhost:48152", "http://[::1]:48152",
        "http://127.0.0.2:48152", "http://127.0.0.1.example.invalid:48152",
        "https://127.0.0.1:48152", "http://name@127.0.0.1:48152",
        "http://127.0.0.1:48152/?query=made-up", "http://127.0.0.1:48152/#made-up",
        "http://127.0.0.1:0", "",
    ])
    func invalidOverride(_ address: String) {
        #expect(throws: ProviderHTTP.Failure(host: "", code: .invalidOverride)) {
            _ = try transport(override: address)
        }
    }

    @Test("a helper inside an app bundle refuses even a loopback override at startup")
    func bundledOverride() {
        let executable = URL(fileURLWithPath: "/tmp/Leverage.app/Contents/MacOS/LeverageHelper")
        #expect(throws: ProviderHTTP.Failure(host: "", code: .invalidOverride)) {
            _ = try transport(override: Self.loopback, executable: executable)
        }
    }

    @Test("a token without a complete twelve-hex marker reaches no connection", arguments: [
        "marker-missing", "pretend-LVRG-TOKEN-a1b2c3d4e5f-unit-test", "pretend-LVRG-TOKEN-a1b2c3d4e5f66-unit-test",
    ])
    func missingMarker(_ token: String) async throws {
        TestProviderProtocol.prepare(.response())
        let http = try transport(override: Self.loopback)
        await #expect(throws: ProviderHTTP.Failure(host: "127.0.0.1", code: .invalidTestToken)) {
            _ = try await http.get(.openaiApi, token: token, timeout: timeout)
        }
        #expect(TestProviderProtocol.requests.isEmpty)
    }

    @Test("the override sends a marked token to loopback on the catalog path")
    func markedToken() async throws {
        TestProviderProtocol.prepare(.response())
        let http = try transport(override: Self.loopback)
        let response = try await http.get(.geminiApi, token: Self.token, timeout: timeout)
        let requests = TestProviderProtocol.requests
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.url?.absoluteString == "\(Self.loopback)/v1beta/models")
        let tokenMatches = request.value(forHTTPHeaderField: "x-goog-api-key") == Self.token
        #expect(tokenMatches)
        #expect(response.status == 200)
    }

    @Test("login providers send no request")
    func loginProvider() async throws {
        TestProviderProtocol.prepare(.response())
        let http = try transport()
        await #expect(throws: ProviderHTTP.Failure(host: "", code: .unsupportedProvider)) {
            _ = try await http.get(.claude, token: Self.token, timeout: timeout)
        }
        #expect(TestProviderProtocol.requests.isEmpty)
    }

    @Test("a network error gives a sanitized host and code after only one attempt")
    func networkError() async throws {
        TestProviderProtocol.prepare(.networkError(Self.token))
        let http = try transport()
        do {
            _ = try await http.get(.grokApi, token: Self.token, timeout: timeout)
            Issue.record("expected a provider HTTP error")
        } catch let failure as ProviderHTTP.Failure {
            #expect(failure == ProviderHTTP.Failure(host: "api.x.ai", code: .unreachable))
            let containsToken = String(reflecting: failure).contains(Self.token)
                || failure.localizedDescription.contains(Self.token)
            #expect(!containsToken)
        }
        #expect(TestProviderProtocol.requests.count == 1)
    }

    @Test("a stalled response reaches the read limit and the connection is stopped")
    func timedOut() async throws {
        TestProviderProtocol.prepare(.response(finish: false))
        let http = try transport()
        await #expect(throws: ProviderHTTP.Failure(host: "api.x.ai", code: .timedOut)) {
            _ = try await http.get(.grokApi, token: Self.token, timeout: .seconds(2))
        }
        try #require(TestProviderProtocol.requests.count == 1)
        #expect(await eventually { TestProviderProtocol.stopped })
    }

    @Test("cancelling a request ends its connection")
    func cancelled() async throws {
        TestProviderProtocol.prepare(.response(finish: false))
        let http = try transport()
        let request = Task {
            defer { TestProviderProtocol.recordReturn() }
            return try await http.get(.openaiApi, token: Self.token, timeout: timeout)
        }
        let started = await eventually { TestProviderProtocol.requests.count == 1 || TestProviderProtocol.returned }
        request.cancel()
        await #expect(throws: CancellationError.self) { _ = try await request.value }
        try #require(started && TestProviderProtocol.requests.count == 1)
        #expect(await eventually { TestProviderProtocol.stopped })
    }

    @Test("a redirect to the same loopback server is refused without a second request")
    func redirect() async throws {
        // URLProtocol can supply a 302 response, but a real HTTP exchange with
        // a stand-in also proves URLSession does not follow Location itself.
        let server = try Subprocess.startSession(SubprocessRequest(
            executable: "/usr/bin/env", arguments: ["python3", "-c", Self.redirectServer],
            environment: [EnvironmentKeys.path: "/usr/bin:/bin"],
            timeLimit: timeout, gracePeriod: .seconds(1)))
        defer { server.stop() }
        do {
            let line = try #require(await server.readLine())
            let port = try #require(Int(String(decoding: line, as: UTF8.self)))
            let http = try ProviderHTTP(
                executableURL: Self.executable,
                environment: [EnvironmentKeys.providerAPIBase: "http://127.0.0.1:\(port)"])
            await #expect(throws: ProviderHTTP.Failure(host: "127.0.0.1", code: .redirect)) {
                _ = try await http.get(.openaiApi, token: Self.token, timeout: timeout)
            }
        } catch {
            server.stop()
            _ = await server.wait()
            throw error
        }
        server.stop()
        let result = await server.wait()
        let paths = String(decoding: result.standardOutput, as: UTF8.self).split(separator: "\n").dropFirst()
        #expect(Array(paths) == ["/v1/models"])
    }

    private static let redirectServer = """
        import os
        from http.server import BaseHTTPRequestHandler, HTTPServer

        class Redirect(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_GET(self):
                print(self.path, flush=True)
                if self.path == '/v1/models':
                    self.send_response(302)
                    self.send_header('Location', '/redirected')
                else:
                    self.send_response(200)
                self.send_header('Content-Length', '0')
                self.end_headers()

        parent = os.getppid()
        with HTTPServer(('127.0.0.1', 0), Redirect) as server:
            server.timeout = 0.25
            print(server.server_port, flush=True)
            while parent != 1 and os.getppid() == parent:
                server.handle_request()
        """

    private func transport(override: String? = nil, executable: URL = Self.executable) throws -> ProviderHTTP {
        let environment = override.map { [EnvironmentKeys.providerAPIBase: $0] } ?? [:]
        return try ProviderHTTP(executableURL: executable, environment: environment,
                                protocolClasses: [TestProviderProtocol.self])
    }

    struct Route: Sendable {
        let provider: Provider
        let address: String
        let header: String

        init(_ provider: Provider, _ address: String, header: String = "Authorization") {
            self.provider = provider
            self.address = address
            self.header = header
        }
    }
}

/// A stand-in for HTTPS replies with headers, streamed chunks, or a stall.
private final class TestProviderProtocol: URLProtocol, @unchecked Sendable {
    enum Answer {
        case reply(status: Int, headers: [String: String], chunks: [Data], finish: Bool)
        case networkError(String)

        static func response(
            status: Int = 200, headers: [String: String] = [:], chunks: [Data] = [], finish: Bool = true
        ) -> Self {
            .reply(status: status, headers: headers, chunks: chunks, finish: finish)
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var answer: Answer = .response()
    nonisolated(unsafe) private static var seen: [URLRequest] = []
    nonisolated(unsafe) private static var ended = false
    nonisolated(unsafe) private static var returnedEarly = false

    static func prepare(_ answer: Answer) {
        lock.withLock {
            self.answer = answer
            seen = []
            ended = false
            returnedEarly = false
        }
    }

    static var requests: [URLRequest] { lock.withLock { seen } }
    static var stopped: Bool { lock.withLock { ended } }
    static var returned: Bool { lock.withLock { returnedEarly } }
    static func recordReturn() { lock.withLock { returnedEarly = true } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let answer = Self.lock.withLock {
            Self.seen.append(request)
            return Self.answer
        }
        guard let url = request.url else { return }
        switch answer {
        case .networkError(let detail):
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost, userInfo: [
                NSURLErrorFailingURLStringErrorKey: detail,
                NSLocalizedDescriptionKey: detail,
            ]))
        case .reply(let status, let headers, let chunks, let finish):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .allowed)
            for chunk in chunks { client?.urlProtocol(self, didLoad: chunk) }
            if finish { client?.urlProtocolDidFinishLoading(self) }
        }
    }

    override func stopLoading() { Self.lock.withLock { Self.ended = true } }
}
