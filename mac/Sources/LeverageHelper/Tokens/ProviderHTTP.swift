import Foundation
import LeverageKit

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The single catalog request used to check a token or read its usage (TK-2).
/// Errors carry only a known host and a code, even when Foundation's error
/// includes details of the original request or provider reply.
struct ProviderHTTP: Sendable {
    struct Response: Sendable {
        let status: Int
        let headers: [String: String]
        let body: Data
    }

    struct Failure: Error, Equatable {
        enum Code: String, Sendable {
            case invalidOverride, unsupportedProvider, invalidTestToken, redirect, bodyTooLarge, unreachable, timedOut
        }

        let host: String
        let code: Code

        var checkFailure: HelperCheckFailure {
            switch code {
            case .timedOut: .timedOut
            case .unreachable: .unreachable
            case .invalidOverride, .unsupportedProvider, .invalidTestToken, .redirect, .bodyTooLarge: .noAnswer
            }
        }
    }

    private static let loopback = "127.0.0.1"
    private static let testMarker = #"LVRG-TOKEN-[0-9a-fA-F]{12}(?![0-9a-fA-F])"#
    private let loopbackBase: URL?
    private let protocolClasses: [AnyClass]?

    init() {
        loopbackBase = nil
        protocolClasses = nil
    }

    /// Read the override once, at helper startup. Only a development helper
    /// outside an app bundle can send test requests to the loopback origin.
    init(executableURL: URL, environment: [String: String], protocolClasses: [AnyClass]? = nil) throws {
        self.protocolClasses = protocolClasses
        guard let override = environment[EnvironmentKeys.providerAPIBase] else {
            loopbackBase = nil
            return
        }
        guard !TokenVaults.isBundled(executableURL: executableURL),
              let address = URLComponents(string: override), address.scheme?.lowercased() == "http",
              address.percentEncodedHost == Self.loopback, address.user == nil, address.password == nil,
              address.query == nil, address.fragment == nil, address.path.isEmpty || address.path == "/",
              address.port.map({ (1...65_535).contains($0) }) ?? true,
              let base = address.url
        else { throw Failure(host: "", code: .invalidOverride) }
        loopbackBase = base
    }

    func get(_ provider: Provider, token: String, timeout: Duration) async throws -> Response {
        try Task.checkCancellation()
        guard let entry = ProviderCatalog.tokenEntry(for: provider) else {
            throw Failure(host: "", code: .unsupportedProvider)
        }
        let address: URL
        if let loopbackBase {
            guard token.range(of: Self.testMarker, options: .regularExpression) != nil else {
                throw Failure(host: Self.loopback, code: .invalidTestToken)
            }
            address = loopbackBase.appending(path: String(entry.url.value.path.drop(while: { $0 == "/" })))
        } else {
            address = entry.url.value
        }
        let host = address.host() ?? ""
        guard timeout > .zero else { throw Failure(host: host, code: .timedOut) }

        let (seconds, attoseconds) = timeout.components
        let interval = Double(seconds) + Double(attoseconds) / 1e18
        var request = URLRequest(url: address, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: interval)
        request.httpMethod = entry.method.value
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (header, value) in entry.extraHeaders.value { request.setValue(value, forHTTPHeaderField: header) }
        let auth = entry.authentication.value
        request.setValue(auth.scheme.map { "\($0) \(token)" } ?? token, forHTTPHeaderField: auth.header)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = protocolClasses ?? configuration.protocolClasses
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = interval
        configuration.timeoutIntervalForResource = interval
        let transfer = ProviderReplyTransfer(host: host, headerNames: TokenReaders.responseHeaders(for: provider))
        let session = URLSession(configuration: configuration, delegate: transfer, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        // An absolute deadline also bounds a response whose data keeps
        // arriving slowly enough to reset URLSession's idle timer.
        let deadline = ContinuousClock.now.advanced(by: timeout)
        let sentRequest = request
        let reply = try await withThrowingTaskGroup(of: Response.self) { group in
            group.addTask { try await transfer.send(sentRequest, session: session) }
            group.addTask {
                try await Task.sleep(until: deadline, clock: .continuous)
                throw Failure(host: host, code: .timedOut)
            }
            defer { group.cancelAll() }
            guard let reply = try await group.next() else { throw Failure(host: host, code: .unreachable) }
            return reply
        }
        try Task.checkCancellation()
        return reply
    }
}

/// URLSession calls the delegate on a serial queue, which owns the reply
/// fields. Cancellation may come from another task, so the pending task and
/// continuation are protected by the lock and taken exactly once.
private final class ProviderReplyTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private typealias Response = ProviderHTTP.Response
    private typealias Failure = ProviderHTTP.Failure
    private static let maximumBodyBytes = 1 << 20
    private let host: String
    private let headerNames: [String]
    private let lock = NSLock()
    private var pending: (task: URLSessionDataTask, continuation: CheckedContinuation<Response, any Error>)?
    private var cancelled = false
    private var status: Int?
    private var headers = [String: String]()
    private var body = Data()

    init(host: String, headerNames: [String]) {
        self.host = host
        self.headerNames = headerNames
    }

    func send(_ request: URLRequest, session: URLSession) async throws -> ProviderHTTP.Response {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let started = lock.withLock {
                    guard !cancelled else { return false }
                    let task = session.dataTask(with: request)
                    pending = (task, continuation)
                    task.resume()
                    return true
                }
                if !started { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let running = lock.withLock {
                cancelled = true
                let running = pending
                pending = nil
                return running
            }
            running?.task.cancel()
            running?.continuation.resume(throwing: CancellationError())
        }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            finish(.failure(Failure(host: host, code: .unreachable)))
            completionHandler(.cancel)
            return
        }
        guard !(300..<400).contains(http.statusCode) else {
            finish(.failure(Failure(host: host, code: .redirect)))
            completionHandler(.cancel)
            return
        }
        status = http.statusCode
        for name in headerNames { headers[name] = http.value(forHTTPHeaderField: name) }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard data.count <= Self.maximumBodyBytes - body.count else {
            finish(.failure(Failure(host: host, code: .bodyTooLarge)))
            dataTask.cancel()
            return
        }
        body.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if (error as? URLError)?.code == .timedOut {
            finish(.failure(Failure(host: host, code: .timedOut)))
        } else if error == nil, let status {
            finish(.success(Response(status: status, headers: headers, body: body)))
        } else {
            finish(.failure(Failure(host: host, code: .unreachable)))
        }
    }

    private func finish(_ result: Result<Response, any Error>) {
        let continuation = lock.withLock {
            let continuation = pending?.continuation
            pending = nil
            return continuation
        }
        continuation?.resume(with: result)
    }
}
