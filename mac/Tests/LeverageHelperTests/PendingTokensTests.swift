import Foundation
import LeverageTestSupport
import Testing

@testable import LeverageHelper

@Suite("Pending API tokens", .timeLimit(.minutes(Patience.minutes(1))))
struct PendingTokensTests {
    private let credentialID = UUID()
    private let token = "LVRG-TOKEN-8acbea194b70"

    @Test("a waiting add takes the token that arrives four seconds later")
    func arrivesWithinDeadline() async throws {
        let clock = PendingTokenTestClock()
        let pending = clock.pendingTokens()
        let (task, completed) = beginTake(from: pending, expecting: token)
        defer { task.cancel() }

        try #require(await eventually(within: 2) { clock.scheduled(after: .seconds(5)) })
        clock.advance(by: .seconds(4))
        await pending.insert(token, credentialID: credentialID)

        #expect(await eventually(within: 2) { completed.value == true })
    }

    @Test("an add cannot take a token arriving after five seconds even before its timeout wakes")
    func arrivesAfterDeadline() async throws {
        let clock = PendingTokenTestClock()
        let pending = clock.pendingTokens()
        let (task, completed) = beginTake(from: pending, expecting: nil)
        defer { task.cancel() }

        try #require(await eventually(within: 2) { clock.scheduled(after: .seconds(5)) })
        clock.canWake.value = false
        clock.advance(by: .seconds(5) + .milliseconds(1))
        await pending.insert(token, credentialID: credentialID)
        clock.canWake.value = true

        #expect(await eventually(within: 2) { completed.value == true })
    }

    @Test("two adds can take a pending token only once")
    func takenOnce() async throws {
        let clock = PendingTokenTestClock()
        let pending = clock.pendingTokens()
        await pending.insert(token, credentialID: credentialID)

        let received = Locked(0)
        let completed = Locked(0)
        let tasks = (0..<2).map { _ in
            Task {
                if await pending.take(credentialID: credentialID) == token {
                    received.update { $0 += 1 }
                }
                completed.update { $0 += 1 }
            }
        }
        defer { tasks.forEach { $0.cancel() } }

        try #require(await eventually(within: 2) { clock.scheduled(after: .seconds(5)) })
        clock.advance(by: .seconds(5))
        try #require(await eventually(within: 2) { completed.value == tasks.count })
        #expect(received.value == 1)
    }

    @Test("a pending token expires after sixty seconds")
    func expires() async throws {
        let clock = PendingTokenTestClock()
        let pending = clock.pendingTokens()
        await pending.insert(token, credentialID: credentialID)

        try #require(await eventually(within: 2) { clock.scheduled(after: .seconds(60)) })
        clock.canWake.value = false
        clock.advance(by: .seconds(60))
        let (task, completed) = beginTake(from: pending, expecting: nil)
        defer { task.cancel() }
        try #require(await eventually(within: 2) { clock.scheduled(after: .seconds(65)) })
        clock.advance(by: .seconds(5))
        clock.canWake.value = true

        #expect(await eventually(within: 2) { completed.value == true })
    }

    @Test("discarding a credential wakes its waiting add without a token")
    func discardWakesTake() async throws {
        let clock = PendingTokenTestClock()
        let pending = clock.pendingTokens()
        let (task, completed) = beginTake(from: pending, expecting: nil)
        defer { task.cancel() }

        try #require(await eventually(within: 2) { clock.scheduled(after: .seconds(5)) })
        await pending.discard(credentialID: credentialID)

        #expect(await eventually(within: 2) { completed.value == true })
    }

    private func beginTake(
        from pending: PendingTokens, expecting expected: String?
    ) -> (Task<Void, Never>, Locked<Bool?>) {
        let completed = Locked<Bool?>(nil)
        let task = Task {
            completed.value = await pending.take(credentialID: credentialID) == expected
        }
        return (task, completed)
    }
}

private struct PendingTokenTestClock: Sendable {
    private let start = ContinuousClock.now
    private let elapsed = Locked(Duration.zero)
    private let deadlines = Locked<Set<ContinuousClock.Instant>>([])
    let canWake = Locked(true)

    func advance(by duration: Duration) { elapsed.update { $0 += duration } }
    func scheduled(after duration: Duration) -> Bool { deadlines.value.contains(start + duration) }

    func pendingTokens() -> PendingTokens {
        PendingTokens(now: { start + elapsed.value }, sleep: { deadline in
            _ = deadlines.update { $0.insert(deadline) }
            while !canWake.value || start + elapsed.value < deadline {
                try await Task.sleep(for: .milliseconds(1))
            }
            try Task.checkCancellation()
        })
    }
}
