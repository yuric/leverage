import Foundation
import LeverageKit
import Testing
@testable import LeverageMCP

struct HeartbeatPumpTests {
    @Test func heartbeatsOnlyHeldWorkAndOnlyWhileTheWindowIsOpen() async throws {
        let clock = ManualMCPClock()
        let fake = RecordingTransport([claim(taskID)])
        let caller = ToolCaller(transport: fake.send, now: clock.now)
        let catalog = ToolCatalog()
        let claim = try #require(catalog.tool(named: "claim_next_task"))
        let next = try #require(catalog.tool(named: "get_next"))
        let schedule = ManualSchedule(clock: clock, ticks: 13) { tick in
            if tick == 1 { _ = await caller.call(claim, arguments: [:]) }
            if tick == 13 { _ = await caller.call(next, arguments: ["wait": .number(0)]) }
        }
        let pump = HeartbeatPump(caller: caller, sleep: schedule.sleep, now: clock.now)
        await pump.run()

        let requests = await fake.requests
        // Claim at t=60, ten beats at t=60 through t=600, no beats at
        // t=660/720, then a new tool call and a beat at t=780.
        #expect(requests.map(\.operation) ==
                [.claimNextTask] + Array(repeating: .heartbeatTask, count: 10) + [.getNext, .heartbeatTask])
        #expect(requests.filter { $0.operation == .heartbeatTask }.allSatisfy {
            $0.path == ["id": taskID] && $0.key != nil
        })
        #expect(await schedule.intervals.allSatisfy { $0 == .seconds(60) })
    }

    @Test func beatsReviewsAndStopsAfterARefusedHeartbeat() async throws {
        let clock = ManualMCPClock()
        let fake = RecordingTransport([claim(reviewID, kind: "review"), refused(.leaseExpired)])
        let caller = ToolCaller(transport: fake.send, now: clock.now)
        let review = try #require(ToolCatalog().tool(named: "claim_next_review"))
        _ = await caller.call(review, arguments: [:])
        let schedule = ManualSchedule(clock: clock, ticks: 3)
        await HeartbeatPump(caller: caller, sleep: schedule.sleep, now: clock.now).run()
        let requests = await fake.requests
        #expect(requests.map(\.operation) == [.claimNextReview, .heartbeatReview])
        #expect(requests.last?.path == ["id": reviewID])
    }

    @Test func transportTimeDoesNotDelayTheNextScheduledBeat() async throws {
        let clock = ManualMCPClock()
        let fake = RecordingTransport([claim(taskID)])
        let caller = ToolCaller(transport: { request in
            if request.operation == .heartbeatTask { clock.advance(by: .seconds(3)) }
            return await fake.send(request)
        }, now: clock.now)
        let claim = try #require(ToolCatalog().tool(named: "claim_next_task"))
        _ = await caller.call(claim, arguments: [:])
        let schedule = ManualSchedule(clock: clock, ticks: 3)
        await HeartbeatPump(caller: caller, sleep: schedule.sleep, now: clock.now).run()

        #expect(await fake.requests.map(\.operation) ==
                [.claimNextTask, .heartbeatTask, .heartbeatTask, .heartbeatTask])
        #expect(await schedule.intervals == [.seconds(60), .seconds(57), .seconds(57)])
        #expect(clock.now() == .seconds(183))
    }

    @Test(arguments: [NextKind.action, .rework, .resume, .briefingChanged])
    func nextNoticeStartsHeartbeatingTheTask(kind: NextKind) async throws {
        let clock = ManualMCPClock()
        let fake = RecordingTransport([nextItem(kind, task: taskID)])
        let caller = ToolCaller(transport: fake.send, now: clock.now)
        let next = try #require(ToolCatalog(role: .builder).tool(named: "get_next"))
        _ = await caller.call(next, arguments: ["wait": .number(0)])
        let schedule = ManualSchedule(clock: clock, ticks: 1)
        await HeartbeatPump(caller: caller, sleep: schedule.sleep, now: clock.now).run()

        let requests = await fake.requests
        #expect(requests.map(\.operation) == [.getNext, .heartbeatTask])
        #expect(requests.last?.path == ["id": taskID])
    }

    @Test func changedReviewBriefingStartsHeartbeatingTheReview() async throws {
        let clock = ManualMCPClock()
        let fake = RecordingTransport([nextItem(.briefingChanged, task: taskID, review: reviewID)])
        let caller = ToolCaller(transport: fake.send, now: clock.now)
        let next = try #require(ToolCatalog(role: .reviewer).tool(named: "get_next"))
        _ = await caller.call(next, arguments: ["wait": .number(0)])
        let schedule = ManualSchedule(clock: clock, ticks: 1)
        await HeartbeatPump(caller: caller, sleep: schedule.sleep, now: clock.now).run()

        let requests = await fake.requests
        #expect(requests.map(\.operation) == [.getNext, .heartbeatReview])
        #expect(requests.last?.path == ["id": reviewID])
    }

    @Test(arguments: [NextKind.none, .task, .review])
    func offersWithoutHeldWorkDoNotHeartbeat(kind: NextKind) async throws {
        let clock = ManualMCPClock()
        let fake = RecordingTransport([nextItem(kind)])
        let caller = ToolCaller(transport: fake.send, now: clock.now)
        let next = try #require(ToolCatalog().tool(named: "get_next"))
        _ = await caller.call(next, arguments: ["wait": .number(0)])
        let schedule = ManualSchedule(clock: clock, ticks: 2)
        await HeartbeatPump(caller: caller, sleep: schedule.sleep, now: clock.now).run()
        #expect(await fake.requests.map(\.operation) == [.getNext])
    }
}

final class ManualMCPClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: Duration = .zero

    func now() -> Duration { lock.withLock { time } }
    func advance(by duration: Duration) { lock.withLock { time += duration } }
}

private actor ManualSchedule {
    private let clock: ManualMCPClock
    private let ticks: Int
    private let onTick: @Sendable (Int) async -> Void
    private(set) var intervals: [Duration] = []

    init(clock: ManualMCPClock, ticks: Int, onTick: @escaping @Sendable (Int) async -> Void = { _ in }) {
        self.clock = clock
        self.ticks = ticks
        self.onTick = onTick
    }

    func sleep(_ interval: Duration) async throws {
        guard intervals.count < ticks else { throw CancellationError() }
        intervals.append(interval)
        clock.advance(by: interval)
        await onTick(intervals.count)
    }
}
