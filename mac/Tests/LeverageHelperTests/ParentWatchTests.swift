import Foundation
import LeverageKit
import LeverageTestSupport
import Testing

@testable import LeverageHelper

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// When the app that started the helper is gone (a crash, Force Quit), the
/// helper stops its runs and exits, so no helper and no run outlives the app
/// (PK-8).
@Suite("Parent watch", .timeLimit(.minutes(Patience.minutes(1))))
struct ParentWatchTests {
    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Int32] = []
        func set(_ value: Int32 = 0) { lock.withLock { values.append(value) } }
        var all: [Int32] { lock.withLock { values } }
    }

    @Test("it notices that the process it watches is gone")
    func noticesExit() async throws {
        let sleeper = try startSleeper()
        let gone = Flag()
        let watch = ParentWatch(watching: sleeper.processID, interval: .milliseconds(50)) { gone.set() }
        watch.start()
        defer { watch.cancel() }

        try await Task.sleep(for: .milliseconds(200))
        #expect(gone.all.isEmpty)

        sleeper.stop()
        _ = await sleeper.wait()
        #expect(await eventually { gone.all.count == 1 })
        try await Task.sleep(for: .milliseconds(200))
        #expect(gone.all.count == 1)
    }

    @Test("a process already gone when the watch starts is noticed at once")
    func alreadyGone() async throws {
        let sleeper = try startSleeper()
        sleeper.stop()
        _ = await sleeper.wait()
        let gone = Flag()
        let watch = ParentWatch(watching: sleeper.processID, interval: .milliseconds(50)) { gone.set() }

        watch.start()
        defer { watch.cancel() }

        #expect(await eventually { gone.all.count == 1 })
    }

    @Test("when the app is gone the helper stops its runs and exits")
    func helperStopsRunsAndExits() async throws {
        let rig = try HelperRig()
        let runtime = HelperRuntime(api: rig.api, settings: rig.settings, timings: fastTimings, log: quietLog)
        let credential = UUID()
        _ = try rig.folders.createFresh(for: credential)
        let started = await runtime.handle(helperRequest(
            .startSeat, seat: UUID(), credential: credential, params: .init(provider: .claude, role: .builder)))
        #expect(started?.outcome == .finished)
        #expect(await eventually { (try? rig.tools.runnerStarts().count) == 1 })
        let run = try #require(try rig.tools.runnerStarts().first)

        let app = try startSleeper()
        let exited = Flag()
        let watch = ParentWatch(watching: app.processID, interval: .milliseconds(50)) {
            Task {
                await runtime.shutdown()
                exited.set(HelperExitCode.stopped)
            }
        }
        watch.start()
        defer { watch.cancel() }

        app.stop()
        _ = await app.wait()

        #expect(await eventually { exited.all == [0] })
        #expect(!isAlive(run.pid) && !isAlive(run.childPid))
        #expect(rig.calls(.reportRunStopped).first?.body?["stop_reason"]?.stringValue == "stopped")
    }

    @Test("the helper watches the app that started it, and stops once when the app is gone")
    func helperWatchesItsParent() async throws {
        let app = try startSleeper()
        let gone = Flag()
        let watch = try #require(HelperParent.watch(parent: app.processID, interval: .milliseconds(50)) { gone.set() })
        defer { watch.cancel() }

        try await Task.sleep(for: .milliseconds(200))
        #expect(gone.all.isEmpty)

        app.stop()
        _ = await app.wait()
        #expect(await eventually { gone.all.count == 1 })
        try await Task.sleep(for: .milliseconds(200))
        #expect(gone.all.count == 1)
    }

    @Test("a helper whose app was gone before it looked (its parent is already launchd) stops at once")
    func helperParentAlreadyGone() {
        for parent: pid_t in [1, 0] {
            let gone = Flag()
            #expect(HelperParent.watch(parent: parent) { gone.set() } == nil)
            #expect(gone.all.count == 1, "parent \(parent)")
        }
    }

    @Test("a helper whose app was gone before it looked ends its request loop with the stopped code")
    func helperParentAlreadyGoneEndsTheLoop() async throws {
        let rig = try HelperRig()
        let runtime = HelperRuntime(api: rig.api, settings: rig.settings, timings: fastTimings, log: quietLog)
        let stopped = Flag()
        let watch = HelperParent.watch(parent: 1) {
            Task {
                await runtime.shutdown()
                stopped.set()
            }
        }
        defer { watch?.cancel() }

        let running = Task { await runtime.run() }
        let stoppedByTheWatch = await eventually { stopped.all.count == 1 }
        #expect(stoppedByTheWatch)
        // Otherwise the loop would run until the suite's time limit.
        if !stoppedByTheWatch { await runtime.shutdown() }
        #expect(await running.value == HelperExitCode.stopped)
    }

    @Test("after shutdown the request loop ends and the helper's run answers the stopped code")
    func shutdownEndsTheLoop() async throws {
        let rig = try HelperRig()
        let runtime = HelperRuntime(api: rig.api, settings: rig.settings, timings: fastTimings, log: quietLog)

        let running = Task { await runtime.run() }
        #expect(await eventually { !rig.calls(.getHelperNext).isEmpty })
        await runtime.shutdown()

        #expect(await running.value == HelperExitCode.stopped)
    }

    @Test("on 401 the helper stops its runs and answers exit code 3")
    func unauthorizedStopsRuns() async throws {
        let rig = try HelperRig()
        let runtime = HelperRuntime(api: rig.api, settings: rig.settings, timings: fastTimings, log: quietLog)
        let credential = UUID()
        _ = try rig.folders.createFresh(for: credential)
        _ = await runtime.handle(helperRequest(
            .startSeat, seat: UUID(), credential: credential, params: .init(provider: .claude, role: .builder)))
        #expect(await eventually { (try? rig.tools.runnerStarts().count) == 1 })
        let run = try #require(try rig.tools.runnerStarts().first)
        rig.api.script { $0.next = { _ in throw TransportError(code: .unauthenticated, message: "made up") } }

        let code = await runtime.run()

        #expect(code == 3)
        #expect(await eventually { !isAlive(run.pid) })
    }
}
