import Foundation
import LeverageKit

/// One run of `LeverageRunner` the helper started for a seat, on one
/// credential (the account it runs on, plan §2.2).
final class SeatRun: @unchecked Sendable {
    let seatID: UUID
    let credentialID: UUID
    /// The tool's version as the helper found it when it started the run.
    let toolVersion: String
    let process: RunningSubprocess

    private let lock = NSLock()
    // Guarded by `lock`.
    private var stopAsked = false
    private var handedOver = false
    private var watcher: Task<Void, Never>?

    init(seatID: UUID, credentialID: UUID, toolVersion: String, process: RunningSubprocess) {
        self.seatID = seatID
        self.credentialID = credentialID
        self.toolVersion = toolVersion
        self.process = process
    }

    /// True once the helper asked the run to stop.
    var stopWasAsked: Bool { lock.withLock { stopAsked } }

    /// True once a new run of the seat took its place (HD-2): its end is
    /// not reported, because the new run's start follows (HD-10).
    var wasHandedOver: Bool { lock.withLock { handedOver } }

    /// Stops the run because a new run of the seat takes its place.
    func handOver() async {
        lock.withLock { handedOver = true }
        await stop()
    }

    /// The task that waits for the run's end and reports it.
    func watch(with task: Task<Void, Never>) {
        lock.withLock { watcher = task }
    }

    /// Asks the runner to stop (it releases what it holds), ends its group
    /// after the grace period (CL-23), and waits until the end is reported.
    func stop() async {
        lock.withLock { stopAsked = true }
        process.stop()
        await finished()
    }

    /// Waits until the run has ended and its end has been reported.
    func finished() async {
        let task = lock.withLock { watcher }
        await task?.value
    }
}

/// The runs this helper started, by seat.
actor RunRegistry {
    private var runs: [UUID: SeatRun] = [:]

    func add(_ run: SeatRun) {
        runs[run.seatID] = run
    }

    func run(for seat: UUID) -> SeatRun? {
        runs[seat]
    }

    /// Removes this run, unless another run of the seat replaced it.
    func remove(_ run: SeatRun) {
        if runs[run.seatID] === run { runs[run.seatID] = nil }
    }

    var all: [SeatRun] { Array(runs.values) }
    var seats: [UUID] { Array(runs.keys) }
}
