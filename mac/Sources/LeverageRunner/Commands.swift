import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LeverageKit

/// What one command came to, once any retry is over.
enum Sent<Result: Sendable>: Sendable {
    case completed(Result?)
    case refused(RefusalCode)
    /// A failure no retry mends (a transport error such as `422 invalid`,
    /// an answer that cannot be read): the flow releases.
    case failed
}

/// What one read came to.
enum Read<Value: Sendable>: Sendable {
    case value(Value)
    case refused(RefusalCode)
    case failed
}

/// The runner's own reasons to stop the whole loop.
enum RunnerStop: Error, Equatable {
    /// `401`: the seat's token is no longer good (exit code 3).
    case unauthenticated
}

/// What a refusal does to a flow (CL-31).
enum RefusalAction: Equatable {
    /// Read the briefing again, acknowledge it and go on from there.
    case restart
    /// On hold: end the tool, stop heartbeating, keep asking what is next.
    case pause
    /// The lease or the task is gone: end the flow, release nothing.
    case end
    /// Anything else: give the work back.
    case release

    init(_ code: RefusalCode) {
        switch code {
        case .briefingChanged, .briefingNotAcknowledged, .criteriaIncomplete: self = .restart
        case .onHold: self = .pause
        case .leaseExpired, .taskCancelled, .notHolder: self = .end
        default: self = .release
        }
    }
}

/// How the runner treats an error from a call.
enum CallError {
    case cancelled
    case unauthenticated
    /// The request or its answer may have been lost: send it again, with
    /// the same key for a command.
    case retry
    case fatal

    init(_ error: any Error) {
        if error is CancellationError || Task.isCancelled {
            self = .cancelled
        } else if let transport = error as? TransportError {
            self = transport.code == .unauthenticated ? .unauthenticated : .fatal
        } else if error is URLError {
            self = .retry
        } else if case LeverageClientError.unexpectedStatus(let status) = error, status >= 500 {
            self = .retry
        } else {
            self = .fatal
        }
    }
}

/// What the loop and its flows share.
struct FlowContext: Sendable {
    let api: any AgentAPI
    let driver: any ToolDriver
    let timing: RunnerTiming
    let log: Log
    let state: RunnerState
    let workRoot: URL
    let home: String

    /// Sends one command with a key of its own. A network failure sends it
    /// again with the same key, after a pause of at most 2 seconds, for as
    /// long as it takes: a lease that ends meanwhile shows as `lease_expired`
    /// when the server answers again. A pending outcome is asked for by its
    /// key until it is decided.
    func command<Result: Sendable>(
        _ name: String, _ send: @Sendable (IdempotencyKey) async throws -> CommandOutcome<Result>
    ) async throws -> Sent<Result> {
        let key = IdempotencyKey()
        while true {
            do {
                let outcome = try await send(key)
                switch outcome.outcome {
                case .completed: return .completed(outcome.result)
                case .refused:
                    let code = outcome.refusal?.code ?? .invalidState
                    log.info("\(name) refused: \(code.rawValue)")
                    return .refused(code)
                case .pending:
                    try await waitWhilePending(key)
                }
            } catch {
                switch CallError(error) {
                case .cancelled: throw CancellationError()
                case .unauthenticated: throw RunnerStop.unauthenticated
                case .retry:
                    log.warning("\(name) did not reach the server; sending it again")
                    try await Task.sleep(for: timing.errorPause)
                case .fatal:
                    log.error("\(name) failed: \(Self.describe(error))")
                    return .failed
                }
            }
        }
    }

    /// One read, sent again after a network failure.
    func read<Value: Sendable>(_ name: String, _ fetch: @Sendable () async throws -> Value) async throws
        -> Read<Value> {
        while true {
            do {
                return .value(try await fetch())
            } catch LeverageClientError.refused(let refusal) {
                log.info("\(name) refused: \(refusal.code.rawValue)")
                return .refused(refusal.code)
            } catch {
                switch CallError(error) {
                case .cancelled: throw CancellationError()
                case .unauthenticated: throw RunnerStop.unauthenticated
                case .retry: try await Task.sleep(for: timing.errorPause)
                case .fatal:
                    log.error("\(name) failed: \(Self.describe(error))")
                    return .failed
                }
            }
        }
    }

    private func waitWhilePending(_ key: IdempotencyKey) async throws {
        while true {
            try await Task.sleep(for: timing.errorPause)
            if case .value(let outcome) = try await read("get_command", { try await api.command(key: key) }),
               outcome.outcome == .pending {
                continue
            }
            return
        }
    }

    /// An error for a log line: its type and code, never a body.
    static func describe(_ error: any Error) -> String {
        if let transport = error as? TransportError { return "\(transport.status) \(transport.code.rawValue)" }
        if let client = error as? LeverageClientError { return "\(client)" }
        return String(describing: type(of: error))
    }
}

/// What the runner holds and how its tool runs have gone, shared by the
/// loop, its flows and the stop.
final class RunnerState: @unchecked Sendable {
    enum Held: Equatable, Sendable {
        case nothing
        case task(UUID)
        case review(UUID)
    }

    private let lock = NSLock()
    private var heldNow: Held = .nothing
    private var failures = 0

    var held: Held { lock.withLock { heldNow } }
    func hold(_ held: Held) { lock.withLock { heldNow = held } }

    /// Failed tool runs in a row (CL-22).
    var consecutiveToolFailures: Int { lock.withLock { failures } }
    func toolAnswered() { lock.withLock { failures = 0 } }
    func toolFailed() { lock.withLock { failures += 1 } }
}
