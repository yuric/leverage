import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// How often a command is sent again after the network failed it. Only a
/// command is sent again, with the same key, so a repeat writes nothing; a
/// read's caller simply asks again.
public struct RetryPolicy: Equatable, Sendable {
    /// Sends in all, the first included.
    public var attempts: Int
    /// The pause before each further send; at most 2 seconds (CL-31).
    public var pause: Duration

    public init(attempts: Int, pause: Duration) {
        precondition(attempts >= 1, "at least one attempt")
        precondition(pause <= .seconds(2), "never pause more than 2 seconds (CL-31)")
        self.attempts = attempts
        self.pause = pause
    }

    public static let standard = RetryPolicy(attempts: 3, pause: .milliseconds(500))
    public static let none = RetryPolicy(attempts: 1, pause: .zero)
}

/// The one place the Mac side sends a request to the API: the bearer
/// token, the `Idempotency-Key`, JSON both ways, the long-poll timeout, and
/// the status read into a `CommandOutcome`, a model, or a `TransportError`.
/// Paths come from the registry through `ContractOperation` (IN-1).
///
/// Built on `dataTask` under a continuation, which FoundationNetworking has
/// on Linux too, for the end-to-end job.
public struct HTTPTransport: Sendable {
    /// The timeout of a request that does not long-poll.
    public static let requestTimeout: TimeInterval = 30
    /// What a long poll's timeout adds to the seconds the server may hold it.
    public static let longPollMargin: TimeInterval = 15

    public let baseURL: URL
    public let token: String?
    public let retry: RetryPolicy
    private let session: URLSession

    public init(baseURL: URL, token: String? = nil, session: URLSession = .shared, retry: RetryPolicy = .standard) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
        self.retry = retry
    }

    /// The same transport with another bearer token, as after sign-in.
    public func withToken(_ token: String?) -> HTTPTransport {
        HTTPTransport(baseURL: baseURL, token: token, session: session, retry: retry)
    }

    /// A `GET`. 200 decodes into `Answer`; 409 throws its `Refusal` as
    /// `LeverageClientError.refused`; 400, 401, 404 and 422 throw a
    /// `TransportError`. With `waitSeconds` the request long-polls.
    /// `signedIn: false` sends no bearer token (the public calls).
    public func read<Answer: Decodable>(
        _ operation: ContractOperation, _ answer: Answer.Type = Answer.self, path: [String: String] = [:],
        query: [URLQueryItem] = [], waitSeconds: Int? = nil, signedIn: Bool = true
    ) async throws -> Answer {
        precondition(operation.method == .get, "\(operation.rawValue) is not a read")
        var items = query
        if let waitSeconds { items.append(URLQueryItem(name: "wait", value: String(waitSeconds))) }
        var request = try makeRequest(operation, path: path, query: items, signedIn: signedIn)
        if let waitSeconds { request.timeoutInterval = TimeInterval(waitSeconds) + Self.longPollMargin }

        let (status, data) = try await send(request)
        switch status {
        case 200: return try decode(Answer.self, from: data)
        case 409: throw LeverageClientError.refused(try decode(Refusal.self, from: data))
        default: throw failure(status: status, data: data)
        }
    }

    /// A `POST` with its key. 200, 202 and 409 decode into the outcome,
    /// whose kind must match the status; 400, 401, 404 and 422 throw a
    /// `TransportError`. A send the network failed is sent again with the
    /// same key, as `retry` allows.
    public func command<Result: Decodable & Sendable>(
        _ operation: ContractOperation, _ result: Result.Type = Result.self, path: [String: String] = [:],
        body: (any Encodable & Sendable)? = nil, key: IdempotencyKey, signedIn: Bool = true
    ) async throws -> CommandOutcome<Result> {
        precondition(operation.method == .post, "\(operation.rawValue) is not a command")
        var request = try makeRequest(operation, path: path, query: [], signedIn: signedIn)
        request.setValue(key.value, forHTTPHeaderField: "Idempotency-Key")
        if let body {
            request.httpBody = try LeverageJSON.encoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        var attempt = 1
        var answer: (Int, Data)
        while true {
            do {
                answer = try await send(request)
                break
            } catch let error as URLError where Self.isTransient(error) && attempt < retry.attempts {
                try Task.checkCancellation()
                attempt += 1
                try await Task.sleep(for: retry.pause)
            }
        }

        let (status, data) = answer
        let expected: OutcomeKind
        switch status {
        case 200: expected = .completed
        case 202: expected = .pending
        case 409: expected = .refused
        default: throw failure(status: status, data: data)
        }
        let outcome = try decode(CommandOutcome<Result>.self, from: data)
        guard outcome.outcome == expected else { throw LeverageClientError.invalidBody }
        return outcome
    }

    /// The URL of an operation with its path parameters filled in.
    public func url(
        for operation: ContractOperation, path parameters: [String: String] = [:], query: [URLQueryItem] = []
    ) throws -> URL {
        var path = ""
        var rest = Substring(operation.path)
        while let open = rest.firstIndex(of: "{") {
            path += rest[..<open]
            guard let close = rest[open...].firstIndex(of: "}") else { break }
            let name = String(rest[rest.index(after: open)..<close])
            guard let value = parameters[name], !value.isEmpty else {
                throw LeverageClientError.missingPathParameter(name)
            }
            path += value
            rest = rest[rest.index(after: close)...]
        }
        path += rest
        let url = baseURL.appending(path: String(path.drop { $0 == "/" }))
        guard !query.isEmpty else { return url }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw LeverageClientError.invalidBody
        }
        components.queryItems = query
        guard let withQuery = components.url else { throw LeverageClientError.invalidBody }
        return withQuery
    }

    private func makeRequest(
        _ operation: ContractOperation, path: [String: String], query: [URLQueryItem], signedIn: Bool
    ) throws -> URLRequest {
        var request = URLRequest(url: try url(for: operation, path: path, query: query))
        request.httpMethod = operation.method.rawValue
        request.timeoutInterval = Self.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if signedIn, let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func decode<Model: Decodable>(_ type: Model.Type, from data: Data) throws -> Model {
        do {
            return try LeverageJSON.decoder().decode(Model.self, from: data)
        } catch {
            throw LeverageClientError.invalidBody
        }
    }

    /// A transport error when the status and the body's code agree, and
    /// the bare status otherwise.
    private func failure(status: Int, data: Data) -> any Error {
        if let error = try? LeverageJSON.decoder().decode(TransportError.self, from: data), error.status == status {
            return error
        }
        return LeverageClientError.unexpectedStatus(status)
    }

    /// Failures after which the command may not have reached the server, or
    /// its answer was lost: sending it again with its key is safe.
    static func isTransient(_ error: URLError) -> Bool {
        switch error.code {
        case .networkConnectionLost, .timedOut, .cannotConnectToHost, .notConnectedToInternet,
             .cannotFindHost, .dnsLookupFailed:
            true
        default:
            false
        }
    }

    private func send(_ request: URLRequest) async throws -> (Int, Data) {
        let running = RunningTask()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request) { data, response, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let http = response as? HTTPURLResponse {
                        continuation.resume(returning: (http.statusCode, data ?? Data()))
                    } else {
                        continuation.resume(throwing: LeverageClientError.notHTTP)
                    }
                }
                running.start(task)
            }
        } onCancel: {
            running.cancel()
        }
    }
}

/// The data task of one send, so that cancelling the awaiting task cancels
/// it, also when the cancel comes before the task started.
private final class RunningTask: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var cancelled = false

    func start(_ task: URLSessionDataTask) {
        let cancelNow = lock.withLock { () -> Bool in
            self.task = task
            return cancelled
        }
        task.resume()
        if cancelNow { task.cancel() }
    }

    func cancel() {
        let task = lock.withLock { () -> URLSessionDataTask? in
            cancelled = true
            return self.task
        }
        task?.cancel()
    }
}
