import Foundation
import LeverageKit

/// How the request loop ended.
enum LoopEnd: Equatable, Sendable {
    /// The helper's token was ended: `401` (PK-4).
    case unauthorized
    /// The helper is stopping.
    case cancelled
}

/// `GET /v1/helper/next` as a long poll, one task per request, so a long
/// wait in one (an add waiting for the owner's sign-in) never blocks
/// another (a Start), and each request's result reported with a key of its
/// own (IN-23). It never pauses more than 2 seconds between calls, also
/// after an error (CL-31), and ends on `401`.
struct RequestLoop: Sendable {
    /// Does one request; nil reports nothing (the helper is stopping).
    typealias Handle = @Sendable (HelperRequest) async -> HelperRequestResult?

    let api: any HelperAPI
    let timings: HelperTimings
    let log: Log
    let handle: Handle
    let running: RunningRequests

    init(
        api: any HelperAPI, timings: HelperTimings, log: Log, running: RunningRequests = RunningRequests(),
        handle: @escaping Handle
    ) {
        self.api = api
        self.timings = timings
        self.log = log
        self.handle = handle
        self.running = running
    }

    /// Runs until `401` or until the calling task is cancelled; the
    /// requests still running are cancelled then too.
    func run() async -> LoopEnd {
        let end = await poll()
        await running.cancelAll()
        return end
    }

    private func poll() async -> LoopEnd {
        while !Task.isCancelled {
            let next: HelperNext
            do {
                next = try await api.next(wait: timings.longPollSeconds)
            } catch {
                if Self.isUnauthorized(error) {
                    log.error("the helper's token was not accepted; stopping")
                    return .unauthorized
                }
                if Task.isCancelled { break }
                log.warning("could not ask for the next request; asking again")
                try? await Task.sleep(for: timings.pauseAfterError)
                continue
            }
            guard let request = next.request else { continue }
            running.start(request) {
                guard !Task.isCancelled else { return }
                log.info("doing \(request.kind.rawValue) request \(request.id.contractString)")
                guard let result = await handle(request), !Task.isCancelled else { return }
                await report(result, of: request)
            }
        }
        return .cancelled
    }

    /// How many times one result is sent before the helper gives up on it.
    static let reportAttempts = 30

    /// Sends a request's result under one key, again with the same key
    /// while the network or the server fails (a lost result would leave the
    /// request picked up and unfinished), pausing at most 2 seconds between
    /// sends (CL-31), until it is accepted, refused, the helper stops, or
    /// `reportAttempts` sends have failed.
    private func report(_ result: HelperRequestResult, of request: HelperRequest) async {
        let key = IdempotencyKey()
        var pause = timings.pauseAfterError
        for attempt in 1...Self.reportAttempts {
            do {
                _ = try await api.reportRequestResult(requestID: request.id, result, key: key)
                return
            } catch {
                if !Self.isWorthSendingAgain(error) {
                    log.warning("the result of request \(request.id.contractString) was not accepted")
                    return
                }
                if Task.isCancelled || attempt == Self.reportAttempts {
                    log.warning("the result of request \(request.id.contractString) could not be sent")
                    return
                }
                try? await Task.sleep(for: pause)
                pause = min(pause * 2, .seconds(2))
            }
        }
    }

    /// A failure the same send may get past: the network, or the server
    /// answering 5xx. An answer the server gave (a refusal, 4xx) is final.
    static func isWorthSendingAgain(_ error: any Error) -> Bool {
        if error is URLError { return true }
        if case LeverageClientError.unexpectedStatus(let status)? = error as? LeverageClientError { return status >= 500 }
        return false
    }

    /// A `401`, with its transport body or without one.
    static func isUnauthorized(_ error: any Error) -> Bool {
        if let transport = error as? TransportError { return transport.code == .unauthenticated }
        if case LeverageClientError.unexpectedStatus(401)? = error as? LeverageClientError { return true }
        return false
    }
}

/// The requests being done, by id, so a request handed out again while it
/// runs is not done twice.
final class RunningRequests: @unchecked Sendable {
    private struct Running {
        let credentialID: UUID?
        let task: Task<Void, Never>
    }

    private let lock = NSLock()
    private var tasks: [UUID: Running] = [:]
    private var forgotten: Set<UUID> = []

    func start(_ request: HelperRequest, _ work: @escaping @Sendable () async -> Void) {
        lock.withLock {
            guard tasks[request.id] == nil else { return }
            let task = Task { [self] in
                await work()
                finish(request.id)
            }
            tasks[request.id] = Running(credentialID: request.credentialID, task: task)
        }
    }

    private func finish(_ id: UUID) {
        lock.withLock { _ = tasks.removeValue(forKey: id) }
    }

    func isForgotten(_ credentialID: UUID) -> Bool {
        lock.withLock { forgotten.contains(credentialID) }
    }

    func forget(_ credentialID: UUID) -> [Task<Void, Never>] {
        lock.withLock {
            guard forgotten.insert(credentialID).inserted else { return [] }
            return tasks.values.filter { $0.credentialID == credentialID }.map(\.task)
        }
    }

    func cancelAll() async {
        let all = lock.withLock { tasks.values.map(\.task) }
        for task in all { task.cancel() }
        for task in all { await task.value }
    }
}
