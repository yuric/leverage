import Foundation
import LeverageKit
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// How the runner exits. The helper reads the code.
enum RunnerExit: Int32, Sendable {
    /// Stopped, after giving back what it held (CL-23).
    case stopped = 0
    /// The environment is incomplete or refused (`RunnerConfiguration`).
    case configuration = 1
    /// `401`: the seat's token is no longer good.
    case unauthenticated = 3
    /// Three failed tool runs in a row (CL-22).
    case toolFailures = 4
}

/// The loop's timing. Nothing in it sleeps longer than 2 seconds between
/// calls, also after an error (CL-31): the waiting is done by the long
/// poll of `GET /v1/next`.
struct RunnerTiming: Sendable {
    /// `GET /v1/next?wait=`, at most 30.
    var nextWait: Int
    /// The pause after an error before the next call.
    var errorPause: Duration
    /// The pause after an item the seat cannot act on, or a refused claim,
    /// since the item repeats until the seat acts.
    var idlePause: Duration
    /// The wait before the next heartbeat, from the lease's end and now.
    var heartbeatInterval: @Sendable (_ leaseDueAt: Date, _ now: Date) -> Duration

    static let standard = RunnerTiming(
        nextWait: 30, errorPause: .seconds(1), idlePause: .seconds(1), heartbeatInterval: thirdOfWhatIsLeft)

    /// A third of the lease that is left, between 1 second and 10 minutes:
    /// a 60-minute lease is renewed every 10 minutes, so two heartbeats may
    /// be lost before it ends.
    static let thirdOfWhatIsLeft: @Sendable (Date, Date) -> Duration = { due, now in
        let third = (due.timeIntervalSince(now) / 3).rounded(.down)
        return .seconds(Int(min(max(third, 1), 600)))
    }
}

/// `GET /v1/next` to an action, for one seat (plan §2.2). A builder claims
/// a task, and goes on with the one it holds on `rework`, `resume` and
/// `briefing_changed`; a reviewer claims a review, and goes on with it on
/// `briefing_changed`. `stop()` ends the tool and the flow, gives back what
/// the seat holds and makes `run()` return 0 (CL-23).
final class RunnerLoop: @unchecked Sendable {
    /// How long a stop waits to give back what the seat holds. The tool is
    /// given 5 seconds to end before it is forced (Subprocess's grace
    /// period), and the helper ends the runner's group
    /// `StopTimings.runnerStopGrace` (10 seconds) after it asked it to stop
    /// (CL-23), so 4 seconds are left for one call.
    static let giveBackLimit: Duration = StopTimings.runnerGiveBack

    private let role: SeatRole
    private let context: FlowContext
    private let lock = NSLock()
    private var stopping = false
    private var working: Task<RunnerExit, Never>?

    init(
        role: SeatRole, api: any AgentAPI, driver: any ToolDriver, workRoot: URL, home: String,
        timing: RunnerTiming = .standard, log: Log
    ) {
        self.role = role
        context = FlowContext(
            api: api, driver: driver, timing: timing, log: log, state: RunnerState(), workRoot: workRoot, home: home)
    }

    /// Runs until stopped, unauthenticated, or three tool runs failed in a
    /// row; returns the exit code.
    func run() async -> Int32 {
        let task = Task { await loop() }
        let stopped = lock.withLock {
            working = task
            return stopping
        }
        if stopped { task.cancel() }
        let exit = await task.value
        if exit == .stopped {
            // A task of its own, so the stop's cancellation does not reach it,
            // under `giveBackLimit`.
            await Task {
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { await self.giveBack() }
                    group.addTask { try? await Task.sleep(for: Self.giveBackLimit) }
                    await group.next()
                    group.cancelAll()
                }
            }.value
        }
        context.log.info("exiting with code \(exit.rawValue)")
        return exit.rawValue
    }

    /// Asks the loop to stop; safe from any thread, a signal handler's queue
    /// included.
    func stop() {
        let task = lock.withLock {
            stopping = true
            return working
        }
        task?.cancel()
    }

    private func loop() async -> RunnerExit {
        let api = context.api
        let builder = BuilderFlow(context: context)
        let reviewer = ReviewerFlow(context: context)
        while true {
            if Task.isCancelled { return .stopped }
            let item: NextItem
            let asked = ContinuousClock.now
            do {
                item = try await api.next(wait: context.timing.nextWait)
            } catch {
                switch CallError(error) {
                case .cancelled: return .stopped
                case .unauthenticated: return .unauthenticated
                case .retry, .fatal:
                    context.log.warning("get_next failed: \(FlowContext.describe(error))")
                    try? await Task.sleep(for: context.timing.errorPause)
                    continue
                }
            }
            do {
                let acted = try await act(on: item, builder: builder, reviewer: reviewer)
                // A `none` that came back at once, from a server that did not
                // hold the long poll, is not asked again at once either.
                let hurried = item.kind == .none && context.timing.nextWait > 0
                    && ContinuousClock.now - asked < .seconds(1)
                if !acted || hurried { try await Task.sleep(for: context.timing.idlePause) }
            } catch RunnerStop.unauthenticated {
                return .unauthenticated
            } catch {
                if case .cancelled = CallError(error) { return .stopped }
                context.log.error("the flow failed: \(FlowContext.describe(error))")
                try? await Task.sleep(for: context.timing.errorPause)
            }
            if context.state.consecutiveToolFailures >= 3 {
                context.log.error("three tool runs in a row failed")
                return .toolFailures
            }
        }
    }

    /// Acts on one item; false when there was nothing to do with it.
    private func act(on item: NextItem, builder: BuilderFlow, reviewer: ReviewerFlow) async throws -> Bool {
        switch (role, item.kind) {
        case (_, .none):
            return true
        case (.builder, .task):
            return try await builder.claim() != nil
        case (.builder, .rework), (.builder, .resume), (.builder, .briefingChanged):
            guard item.reviewID == nil, let id = item.id.flatMap(UUID.init(uuidString:)) else { return false }
            _ = try await builder.continueTask(id)
            return true
        case (.reviewer, .review):
            return try await reviewer.claim() != nil
        case (.reviewer, .briefingChanged):
            guard let reviewID = item.reviewID else { return false }
            _ = try await reviewer.continueReview(reviewID)
            return true
        default:
            return false
        }
    }

    /// Gives back what the seat holds: the task with `stopping`, or the
    /// review (CL-23). One attempt each; a refusal is fine (the lease may
    /// have ended meanwhile).
    private func giveBack() async {
        let api = context.api
        do {
            switch context.state.held {
            case .nothing:
                return
            case .task(let id):
                _ = try await context.command("release_task") {
                    try await api.releaseTask(taskID: id, reason: .stopping, key: $0)
                }
            case .review(let id):
                _ = try await context.command("release_review") { try await api.releaseReview(reviewID: id, key: $0) }
            }
            context.state.hold(.nothing)
        } catch {
            context.log.warning("could not give back what the seat held: \(FlowContext.describe(error))")
        }
    }
}

extension RunnerLoop {
    /// Turns each signal into `stop()`. The handlers run on a queue, never
    /// inside the signal itself, and outside the main actor (main.swift's
    /// top level is the main actor's, and a handler isolated to it would
    /// trap when the queue calls it). Keep the sources for as long as the
    /// loop runs.
    func stopOnSignals(_ numbers: [Int32]) -> [any DispatchSourceSignal] {
        numbers.map { number in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { [self] in stop() }
            source.resume()
            return source
        }
    }
}
