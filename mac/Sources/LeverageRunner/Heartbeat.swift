import Foundation
import LeverageKit

/// What a heartbeat renews.
enum LeaseSubject: Sendable {
    case task(UUID)
    case review(UUID)
}

/// Renews the lease on a timer while a flow runs. A refusal that ends the
/// lease or the task (`lease_expired`, `task_cancelled`, `not_holder`) ends
/// the flow at once, and with it the tool; when the flow ends for any
/// reason, the heartbeat stops (also on a hold: the lease clock is paused,
/// CL-31).
enum Heartbeat {
    static func around(
        _ subject: LeaseSubject, leaseDue: Date?, context: FlowContext,
        flow: @escaping @Sendable () async throws -> FlowEnd
    ) async throws -> FlowEnd {
        enum Finished: Sendable {
            case flow(FlowEnd)
            case lease(FlowEnd?)
        }
        return try await withThrowingTaskGroup(of: Finished.self) { group in
            group.addTask { .flow(try await flow()) }
            group.addTask { .lease(try await renew(subject, leaseDue: leaseDue, context: context)) }
            defer { group.cancelAll() }
            while let finished = try await group.next() {
                switch finished {
                case .flow(let end):
                    return end
                case .lease(let end?):
                    return end
                case .lease(nil):
                    continue
                }
            }
            throw CancellationError()
        }
    }

    /// Renews until cancelled. Returns how the flow ends when a refusal
    /// says the lease or the task is gone (or the task is on hold); nil
    /// never, in practice, since it runs until it is cancelled.
    static func renew(_ subject: LeaseSubject, leaseDue: Date?, context: FlowContext) async throws -> FlowEnd? {
        var due = leaseDue
        let api = context.api
        while true {
            let now = Date()
            // A lease whose end is not known (a rework's or a resumed task's
            // fresh lease) is treated as ending in three minutes until the
            // first heartbeat says.
            let interval = context.timing.heartbeatInterval(due ?? now.addingTimeInterval(180), now)
            try await Task.sleep(for: interval)
            let sent: Sent<HeartbeatResult>
            switch subject {
            case .task(let id):
                sent = try await context.command("heartbeat_task") { try await api.heartbeatTask(taskID: id, key: $0) }
            case .review(let id):
                sent = try await context.command("heartbeat_review") {
                    try await api.heartbeatReview(reviewID: id, key: $0)
                }
            }
            switch sent {
            case .completed(let result):
                if let result { due = result.leaseDueAt }
            case .refused(let code):
                switch RefusalAction(code) {
                case .end: return .ended
                case .pause: return .paused
                case .restart, .release: continue
                }
            case .failed:
                continue
            }
        }
    }
}
