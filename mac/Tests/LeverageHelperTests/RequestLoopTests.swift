import Foundation
import LeverageKit
import LeverageTestSupport
import Testing

@testable import LeverageHelper

/// The helper's loop: `GET /v1/helper/next`, one task per request, its
/// result reported, exit code 3 on `401` (PK-4, CL-31).
@Suite("Request loop", .timeLimit(.minutes(1)))
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
        rig.api.script { $0.next = { _ in try await queue.next() } }
        let loop = RequestLoop(api: rig.api, timings: HelperTimings.standard, log: quietLog) { _ in
            HelperRequestResult(outcome: .finished, checks: [], toolVersion: nil)
        }
        #expect(HelperTimings.standard.pauseAfterError <= .seconds(2))

        let running = Task { await loop.run() }
        #expect(await eventually(within: 4) { results(rig.api) == [request.id.contractString] })
        running.cancel()
        _ = await running.value
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

    // MARK: The helper's own dispatch

    @Test("the helper answers the kinds this milestone does not serve with a failed result")
    func unservedKinds() async throws {
        let rig = try HelperRig()
        let runtime = HelperRuntime(api: rig.api, settings: rig.settings, timings: fastTimings, log: quietLog)

        for kind in [HelperRequestKind.openSignIn, .readUsage] {
            let result = await runtime.handle(helperRequest(kind, credential: UUID()))
            #expect(result?.outcome == .failed)
        }
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
        let started = await runtime.handle(helperRequest(
            .startSeat, seat: seat, credential: credential, params: .init(provider: .codex, role: .reviewer)))
        #expect(started?.outcome == .finished)
        #expect(await eventually { (try? rig.tools.runnerStarts().count) == 1 })
        let stopped = await runtime.handle(helperRequest(.stopSeat, seat: seat))
        #expect(stopped?.outcome == .finished)
        #expect(rig.calls(.reportRunStopped).count == 1)
    }
}
