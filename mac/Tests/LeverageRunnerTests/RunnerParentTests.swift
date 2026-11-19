import Foundation
import LeverageKit
import Testing

@testable import LeverageRunner

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A runner whose helper is gone (a crash, a SIGKILL) stops the way SIGTERM
/// stops it, so no runner keeps working with a live seat token after the
/// helper that started it (PK-8, CL-23).
@Suite("The runner's parent watch", .timeLimit(.minutes(1)))
struct RunnerParentTests {
    final class Count: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func add() { lock.withLock { value += 1 } }
        var current: Int { lock.withLock { value } }
    }

    @Test("when the process that started the runner is gone, the runner's stop is called once")
    func stopsWhenParentGone() async throws {
        let parent = try Subprocess.start(SubprocessRequest(
            executable: "/bin/sleep", arguments: ["60"], environment: [:], gracePeriod: .seconds(1)))
        let stops = Count()
        let watch = try #require(RunnerParent.watch(parent: parent.processID, interval: .milliseconds(50)) { stops.add() })
        defer { watch.cancel() }

        try await Task.sleep(for: .milliseconds(200))
        #expect(stops.current == 0)

        parent.stop()
        _ = await parent.wait()
        #expect(await eventually { stops.current == 1 })
        try await Task.sleep(for: .milliseconds(200))
        #expect(stops.current == 1)
    }

    @Test("a runner whose parent is already launchd watches nothing")
    func noParentToWatch() {
        #expect(RunnerParent.watch(parent: 1) {} == nil)
        #expect(RunnerParent.watch(parent: 0) {} == nil)
    }

    @Test("a stopping runner's give-back fits inside the helper's grace, and is the shared figure")
    func giveBackIsShared() {
        #expect(RunnerLoop.giveBackLimit == StopTimings.runnerGiveBack)
        #expect(StopTimings.runnerGiveBack < StopTimings.runnerStopGrace)
    }
}
