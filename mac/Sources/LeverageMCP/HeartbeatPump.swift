/// The scheduler can be replaced with a manual one for the lease-window tests.
struct HeartbeatPump: Sendable {
    private static let interval: Duration = .seconds(60)
    private let caller: ToolCaller
    private let sleep: @Sendable (Duration) async throws -> Void
    private let now: @Sendable () -> Duration

    init(
        caller: ToolCaller,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        now: (@Sendable () -> Duration)? = nil
    ) {
        self.caller = caller
        self.sleep = sleep
        let start = ContinuousClock.now
        self.now = now ?? { start.duration(to: .now) }
    }

    func run() async {
        var deadline = now() + Self.interval
        do {
            while !Task.isCancelled {
                try await sleep(max(.zero, deadline - now()))
                try Task.checkCancellation()
                await caller.heartbeat()

                deadline += Self.interval
                let time = now()
                // Do not send a backlog if a request outlasted a tick.
                if deadline <= time { deadline = time + Self.interval }
            }
        } catch {
            // The session ends the schedule when its input closes.
        }
    }
}
