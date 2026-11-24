import Foundation
import LeverageKit
import LeverageTestSupport
import Testing

@testable import LeverageHelper

/// The helper's loop: `GET /v1/helper/next`, one task per request, its
/// result reported, exit code 3 on `401` (PK-4, CL-31).
@Suite("Request loop", .timeLimit(.minutes(Patience.minutes(1))))
struct RequestLoopTests {
    /// Hands out the requests in order, then answers nothing, as a long
    /// poll that comes back empty.
    final class Queue: @unchecked Sendable {
        private let lock = NSLock()
        private var waiting: [Result<HelperRequest, any Error>]
        private(set) var polls = 0

        init(_ items: [Result<HelperRequest, any Error>]) { waiting = items }

        func next() async throws -> HelperNext {
            let item: Result<HelperRequest, any Error>? = lock.withLock {
                polls += 1
                return waiting.isEmpty ? nil : waiting.removeFirst()
            }
            guard let item else {
                try await Task.sleep(for: .milliseconds(20))
                return HelperNext(request: nil)
            }
            return HelperNext(request: try item.get())
        }

        var pollCount: Int { lock.withLock { polls } }
    }

    /// A gate a handler waits behind until the test opens it.
    final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var open = false
        func release() { lock.withLock { open = true } }
        func wait() async {
            while !lock.withLock({ open }) { try? await Task.sleep(for: .milliseconds(10)) }
        }
    }

    final class Handled: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: [UUID] = []
        func add(_ id: UUID) { lock.withLock { ids.append(id) } }
        var all: [UUID] { lock.withLock { ids } }
    }

    private func results(_ api: FakeHelperAPI) -> [String] {
        api.calls.filter { $0.operation == .reportRequestResult }.compactMap { $0.path["id"] }
    }

    @Test("a long wait in one request does not block another")
    func longWaitDoesNotBlock() async throws {
        let rig = try HelperRig()
        let slow = helperRequest(.runAddChecks, credential: UUID())
        let quick = helperRequest(.stopSeat, seat: UUID())
        let queue = Queue([.success(slow), .success(quick)])
        rig.api.script { $0.next = { _ in try await queue.next() } }
        let gate = Gate()
        let loop = RequestLoop(api: rig.api, timings: fastTimings, log: quietLog) { request in
            if request.id == slow.id { await gate.wait() }
            return HelperRequestResult(outcome: .finished, checks: [], toolVersion: nil)
        }

        let running = Task { await loop.run() }
        #expect(await eventually { results(rig.api) == [quick.id.contractString] })
        gate.release()
        #expect(await eventually { results(rig.api) == [quick.id.contractString, slow.id.contractString] })
        running.cancel()
        #expect(await running.value == .cancelled)
    }

    @Test("401 ends the loop with the helper's exit code 3")
    func unauthorizedExits() async throws {
        let rig = try HelperRig()
        rig.api.script { $0.next = { _ in throw TransportError(code: .unauthenticated, message: "made up") } }
        let loop = RequestLoop(api: rig.api, timings: fastTimings, log: quietLog) { _ in nil }

        let end = await loop.run()

        #expect(end == .unauthorized)
        #expect(HelperExitCode.code(for: end) == 3)
        #expect(HelperExitCode.unauthorized == 3)
    }

    @Test("a 401 with no transport body also ends the loop")
    func unexpected401Exits() async throws {
        let rig = try HelperRig()
        rig.api.script { $0.next = { _ in throw LeverageClientError.unexpectedStatus(401) } }
        let loop = RequestLoop(api: rig.api, timings: fastTimings, log: quietLog) { _ in nil }

        #expect(await loop.run() == .unauthorized)
    }

    @Test("after another error it asks again, pausing no more than 2 seconds")
    func errorIsRetried() async throws {
        let rig = try HelperRig()
        let request = helperRequest(.stopSeat, seat: UUID())
        let queue = Queue([.failure(URLError(.networkConnectionLost)), .success(request)])
        let asks = Locked<[ContinuousClock.Instant]>([])
        rig.api.script {
            $0.next = { _ in
                asks.update { $0.append(.now) }
                return try await queue.next()
            }
        }
        let loop = RequestLoop(api: rig.api, timings: HelperTimings.standard, log: quietLog) { _ in
            HelperRequestResult(outcome: .finished, checks: [], toolVersion: nil)
        }
        // The pause is the timing's, and the timing is at most 2 seconds.
        // Both are measured without the wall clock's load: the timing is
        // read, and the gap between the two asks can only be longer than the
        // pause the loop scheduled, never shorter.
        #expect(HelperTimings.standard.pauseAfterError <= .seconds(2))

        let running = Task { await loop.run() }
        #expect(await eventually(within: 4) { results(rig.api) == [request.id.contractString] })
        running.cancel()
        _ = await running.value
        let times = asks.value
        try #require(times.count >= 2)
        #expect(times[1] - times[0] >= HelperTimings.standard.pauseAfterError, "it pauses before asking again")
    }

    @Test("it long-polls with the wait the timings give")
    func longPolls() async throws {
        let rig = try HelperRig()
        let waits = Handled()
        rig.api.script {
            $0.next = { wait in
                if wait == 1 { waits.add(UUID()) }
                try await Task.sleep(for: .milliseconds(20))
                return HelperNext(request: nil)
            }
        }
        let loop = RequestLoop(api: rig.api, timings: fastTimings, log: quietLog) { _ in nil }

        let running = Task { await loop.run() }
        #expect(await eventually { waits.all.count >= 2 })
        running.cancel()
        _ = await running.value
        #expect(HelperTimings.standard.longPollSeconds == 30)
    }

    @Test("a request handed out again while it runs is handled once")
    func sameRequestOnce() async throws {
        let rig = try HelperRig()
        let request = helperRequest(.runAddChecks, credential: UUID())
        let queue = Queue([.success(request), .success(request), .success(request)])
        rig.api.script { $0.next = { _ in try await queue.next() } }
        let gate = Gate()
        let handled = Handled()
        let loop = RequestLoop(api: rig.api, timings: fastTimings, log: quietLog) { request in
            handled.add(request.id)
            await gate.wait()
            return HelperRequestResult(outcome: .finished, checks: [], toolVersion: nil)
        }

        let running = Task { await loop.run() }
        #expect(await eventually { queue.pollCount >= 4 })
        gate.release()
        #expect(await eventually { results(rig.api).count == 1 })
        running.cancel()
        _ = await running.value
        #expect(handled.all == [request.id])
    }

    @Test("each result is sent with a key of its own, and a handler that gives none reports nothing")
    func resultKeys() async throws {
        let rig = try HelperRig()
        let first = helperRequest(.stopSeat, seat: UUID())
        let second = helperRequest(.stopSeat, seat: UUID())
        let silent = helperRequest(.stopSeat, seat: UUID())
        let queue = Queue([.success(first), .success(second), .success(silent)])
        rig.api.script { $0.next = { _ in try await queue.next() } }
        let loop = RequestLoop(api: rig.api, timings: fastTimings, log: quietLog) { request in
            request.id == silent.id ? nil : HelperRequestResult(outcome: .finished, checks: [], toolVersion: nil)
        }

        let running = Task { await loop.run() }
        #expect(await eventually { results(rig.api).count == 2 && queue.pollCount >= 5 })
        running.cancel()
        _ = await running.value
        let keys = rig.calls(.reportRequestResult).compactMap(\.key)
        #expect(Set(keys).count == 2)
        #expect(!results(rig.api).contains(silent.id.contractString))
    }

    @Test("a result the network lost is sent again with the same key until it is accepted")
    func resultSentAgain() async throws {
        let rig = try HelperRig()
        let start = helperRequest(.stopSeat, seat: UUID())
        let queue = Queue([.success(start)])
        let failures = Locked(2)
        rig.api.script {
            $0.next = { _ in try await queue.next() }
            $0.reportRequestResult = { _, _, key in
                let fail = failures.update { left -> Bool in
                    defer { left -= 1 }
                    return left > 0
                }
                if fail { throw URLError(.networkConnectionLost) }
                return .completed(.object([:]), key: key.value, command: .reportRequestResult)
            }
        }
        let loop = RequestLoop(api: rig.api, timings: fastTimings, log: quietLog) { _ in
            HelperRequestResult(outcome: .finished, checks: [], toolVersion: nil)
        }

        let running = Task { await loop.run() }
        #expect(await eventually { results(rig.api).count == 3 })
        try await Task.sleep(for: .milliseconds(200))
        running.cancel()
        _ = await running.value
        let keys = rig.calls(.reportRequestResult).compactMap(\.key)
        #expect(keys.count == 3)
        #expect(Set(keys).count == 1, "every send of one result carries its one key")
    }

    /// Runs a loop that is handed one request whose result `report` answers
    /// (it throws to fail a send), lets it settle, stops it, and returns how
    /// many times the result was sent.
    private func runOneRequest(
        timings: HelperTimings, waitingFor sendsNeeded: Int = 1, report: @escaping @Sendable (Int) throws -> Void
    ) async throws -> Int {
        let rig = try HelperRig()
        let start = helperRequest(.stopSeat, seat: UUID())
        let queue = Queue([.success(start)])
        let sends = Locked(0)
        rig.api.script {
            $0.next = { _ in try await queue.next() }
            $0.reportRequestResult = { _, _, key in
                let number = sends.update { count -> Int in
                    count += 1
                    return count
                }
                try report(number)
                return .completed(.object([:]), key: key.value, command: .reportRequestResult)
            }
        }
        let loop = RequestLoop(api: rig.api, timings: timings, log: quietLog) { _ in
            HelperRequestResult(outcome: .finished, checks: [], toolVersion: nil)
        }
        let running = Task { await loop.run() }
        #expect(await eventually { sends.value >= sendsNeeded && queue.pollCount >= 5 })
        try await Task.sleep(for: .milliseconds(300))
        running.cancel()
        _ = await running.value
        return sends.value
    }

    @Test("a server error is sent again, and any other status is final", arguments: [
        (503, 2), (500, 2), (502, 2), (400, 1), (404, 1), (409, 1), (422, 1),
    ])
    func statusDecidesWhetherToSendAgain(status: Int, sends: Int) async throws {
        let count = try await runOneRequest(
            timings: fastTimings,
            report: { number in if number == 1 { throw LeverageClientError.unexpectedStatus(status) } })
        #expect(count == sends)
    }

    @Test("a result that never gets through is given up on after reportAttempts sends")
    func resultGivenUp() async throws {
        var timings = fastTimings
        timings.pauseAfterError = .zero
        let count = try await runOneRequest(
            timings: timings, waitingFor: RequestLoop.reportAttempts,
            report: { _ in throw URLError(.networkConnectionLost) })
        #expect(count == RequestLoop.reportAttempts)
    }

    @Test("the pause between sends of one result grows but is never more than 2 seconds (CL-31)")
    func resultPauseIsCapped() async throws {
        var timings = fastTimings
        timings.pauseAfterError = .milliseconds(1900)
        let stamps = Locked<[ContinuousClock.Instant]>([])
        let count = try await runOneRequest(
            timings: timings, waitingFor: 3,
            report: { number in
                stamps.update { $0.append(.now) }
                if number <= 2 { throw URLError(.networkConnectionLost) }
            })
        #expect(count == 3)
        let times = stamps.value
        let gaps = zip(times.dropFirst(), times).map { $0 - $1 }
        #expect(gaps.count == 2)
        #expect(gaps.allSatisfy { $0 < .milliseconds(2600) }, "no pause is longer than 2 seconds: \(gaps)")
        #expect(gaps.allSatisfy { $0 > .milliseconds(1500) }, "the pauses are kept: \(gaps)")
    }

    @Test("a result the server refused is not sent again")
    func refusedResultNotSentAgain() async throws {
        let rig = try HelperRig()
        let start = helperRequest(.stopSeat, seat: UUID())
        let queue = Queue([.success(start)])
        rig.api.script {
            $0.next = { _ in try await queue.next() }
            $0.reportRequestResult = { _, _, _ in throw TransportError(code: .invalid, message: "made up") }
        }
        let loop = RequestLoop(api: rig.api, timings: fastTimings, log: quietLog) { _ in
            HelperRequestResult(outcome: .finished, checks: [], toolVersion: nil)
        }

        let running = Task { await loop.run() }
        #expect(await eventually { results(rig.api).count == 1 && queue.pollCount >= 5 })
        try await Task.sleep(for: .milliseconds(200))
        running.cancel()
        _ = await running.value
        #expect(results(rig.api).count == 1)
    }

    // MARK: The helper's own dispatch

    @Test("stop_seat still stops a registered run after its credential is forgotten")
    func stopsSeatAfterCredentialIsForgotten() async throws {
        let rig = try HelperRig()
        let runtime = HelperRuntime(api: rig.api, settings: rig.settings, timings: fastTimings, log: quietLog)
        let seat = UUID()
        let credential = UUID()
        _ = try runtime.cleanup.createFolder(for: credential)
        let start = helperRequest(
            .startSeat, seat: seat, credential: credential, params: .init(provider: .claude, role: .builder))
        let started = await runtime.handle(start)
        #expect(started?.outcome == .finished)
        #expect(await runtime.launcher.runningSeats() == [seat])

        await runtime.cleanup.forget(credential)
        let result = await runtime.handle(helperRequest(.stopSeat, seat: seat, credential: credential))
        let remaining = await runtime.launcher.runningSeats()
        let stopped = rig.calls(.reportRunStopped)
        await runtime.shutdown()

        #expect(result?.outcome == .finished)
        #expect(remaining.isEmpty)
        #expect(stopped.map { $0.path["id"] } == [seat.contractString])
    }

    @Test("forget does not cancel a stop_seat already in flight with that credential ID")
    func forgettingCredentialKeepsInFlightStop() async {
        let running = RunningRequests()
        let gate = Gate()
        let credential = UUID()
        running.start(helperRequest(.stopSeat, seat: UUID(), credential: credential)) {
            await gate.wait()
        }

        let workToCancel = running.forget(credential)
        gate.release()
        await running.cancelAll()

        #expect(workToCancel.isEmpty)
    }

    @Test("the helper dispatches read_usage and reports an unavailable reading for a login with no reader")
    func dispatchesUsage() async throws {
        let rig = try HelperRig()
        rig.api.script {
            $0.reportReading = { _, _, key in
                .completed(.object([:]), key: key.value, command: .reportReading)
            }
        }
        let runtime = HelperRuntime(api: rig.api, settings: rig.settings, timings: fastTimings, log: quietLog)

        let result = await runtime.handle(helperRequest(
            .readUsage, credential: UUID(), params: .init(provider: .gemini, credentialKind: .login)))

        #expect(result?.checks == [HelperCheckResult(check: .readingTaken, passed: true)])
        #expect(rig.calls(.reportReading).count == 1)
        #expect(try rig.tools.calls().isEmpty)
    }

    @Test("the helper sends each kind to the part that does it")
    func dispatch() async throws {
        let rig = try HelperRig()
        let runtime = HelperRuntime(
            api: rig.api, settings: rig.settings, timings: fastTimings, log: quietLog, prober: StandInPrompt())
        let credential = UUID()
        let seat = UUID()

        let added = await runtime.handle(helperRequest(
            .runAddChecks, credential: credential, params: .init(provider: .codex, credentialKind: .login)))
        #expect(added?.outcome == .finished)
        let verified = await runtime.handle(helperRequest(
            .verify, credential: credential, params: .init(provider: .codex, credentialKind: .login)))
        #expect(verified?.outcome == .finished)
        let signedInAgain = await runtime.handle(helperRequest(
            .openSignIn, credential: credential, params: .init(provider: .codex, credentialKind: .login)))
        #expect(signedInAgain?.outcome == .finished)
        #expect(signedInAgain?.checks.count == 3)
        let started = await runtime.handle(helperRequest(
            .startSeat, seat: seat, credential: credential, params: .init(provider: .codex, role: .reviewer)))
        #expect(started?.outcome == .finished)
        #expect(await eventually { (try? rig.tools.runnerStarts().count) == 1 })
        let stopped = await runtime.handle(helperRequest(.stopSeat, seat: seat))
        #expect(stopped?.outcome == .finished)
        #expect(rig.calls(.reportRunStopped).count == 1)
    }
}
