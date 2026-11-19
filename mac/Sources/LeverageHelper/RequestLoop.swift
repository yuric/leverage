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

    init(api: any HelperAPI, timings: HelperTimings, log: Log, handle: @escaping Handle) {
        self.api = api
        self.timings = timings
        self.log = log
        self.handle = handle
    }

    /// Runs until `401` or until the calling task is cancelled; the
    /// requests still running are cancelled then too.
    func run() async -> LoopEnd {
        let running = RunningRequests()
        defer { running.cancelAll() }
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
            running.start(request.id) {
                log.info("doing \(request.kind.rawValue) request \(request.id.contractString)")
                guard let result = await handle(request), !Task.isCancelled else { return }
                await report(result, of: request)
            }
        }
        return .cancelled
    }

    private func report(_ result: HelperRequestResult, of request: HelperRequest) async {
        do {
            _ = try await api.reportRequestResult(requestID: request.id, result, key: IdempotencyKey())
        } catch {
            log.warning("the result of request \(request.id.contractString) was not accepted")
        }
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
    private let lock = NSLock()
    private var tasks: [UUID: Task<Void, Never>] = [:]

    func start(_ id: UUID, _ work: @escaping @Sendable () async -> Void) {
        lock.withLock {
            guard tasks[id] == nil else { return }
            tasks[id] = Task { [self] in
                await work()
                finish(id)
            }
        }
    }

    private func finish(_ id: UUID) {
        lock.withLock { _ = tasks.removeValue(forKey: id) }
    }

    func cancelAll() {
        let all = lock.withLock { Array(tasks.values) }
        for task in all { task.cancel() }
    }
}
