import Foundation
import LeverageKit
import LeverageTestSupport
import Testing

@testable import LeverageApp

/// The server side of a long poll, in memory: each ask is recorded and
/// waits until the test queues an answer for it.
private final class ScriptedEvents: @unchecked Sendable {
    let asked = Locked<[Int]>([])
    private let answers = Locked<[Result<EventsPage, URLError>]>([])

    func answer(_ page: EventsPage) { answers.update { $0.append(.success(page)) } }
    func fail() { answers.update { $0.append(.failure(URLError(.cannotConnectToHost))) } }

    func install(on owner: FakeOwnerAPI) {
        owner.script {
            $0.events = { [self] afterSeq, _, _ in
                asked.update { $0.append(afterSeq) }
                while true {
                    if let next = answers.update({ $0.isEmpty ? nil : $0.removeFirst() }) {
                        return try next.get()
                    }
                    try await Task.sleep(for: .milliseconds(2))
                }
            }
        }
    }
}

@MainActor
@Suite("EventFeed")
struct EventFeedTests {
    private func makeFeed(retryDelay: Duration = .milliseconds(5)) -> (EventFeed, FakeOwnerAPI, ScriptedEvents) {
        let owner = FakeOwnerAPI()
        let server = ScriptedEvents()
        server.install(on: owner)
        return (EventFeed(owner: owner, waitSeconds: 25, retryDelay: retryDelay), owner, server)
    }

    @Test("it asks for nothing until a screen has read and said where its read stood")
    func idleUntilFirstRead() async {
        let (feed, owner, _) = makeFeed()
        try? await Task.sleep(for: .milliseconds(30))
        #expect(owner.calls.isEmpty)
        #expect(feed.connection == .idle)
    }

    @Test("it long-polls from the position of the first read, and each answer moves it on")
    func tailsFromFirstRead() async {
        let (feed, owner, server) = makeFeed()
        let seen = Locked<[[Int]]>([])
        let subscription = feed.subscribe { events in seen.update { $0.append(events.map(\.seq)) } }

        feed.noteRead(asOfSeq: 7)
        #expect(await ShellFixtures.eventually { server.asked.value == [7] })
        server.answer(EventsPage(events: [ShellFixtures.event(seq: 8), ShellFixtures.event(seq: 9)], nextAfterSeq: 9))

        #expect(await ShellFixtures.eventually { server.asked.value == [7, 9] })
        #expect(seen.value == [[8, 9]])
        #expect(feed.revision == 1)
        #expect(feed.connection == .live)
        #expect(owner.calls.allSatisfy { $0.operation == .listEvents })
        subscription.cancel()
        feed.stop()
    }

    @Test("an answer with no events, as when the wait runs out, tells nobody")
    func emptyAnswer() async {
        let (feed, _, server) = makeFeed()
        let seen = Locked(0)
        let subscription = feed.subscribe { _ in seen.update { $0 += 1 } }

        feed.noteRead(asOfSeq: 3)
        #expect(await ShellFixtures.eventually { server.asked.value == [3] })
        server.answer(EventsPage(events: [], nextAfterSeq: 3))
        #expect(await ShellFixtures.eventually { server.asked.value == [3, 3] })

        #expect(seen.value == 0)
        #expect(feed.revision == 0)
        subscription.cancel()
        feed.stop()
    }

    @Test("a read that stood lower than where the feed is moves it back, so no screen misses an event")
    func lowestReadWins() async {
        let (feed, _, server) = makeFeed()
        let seen = Locked<[[Int]]>([])
        let subscription = feed.subscribe { events in seen.update { $0.append(events.map(\.seq)) } }

        feed.noteRead(asOfSeq: 10)
        #expect(await ShellFixtures.eventually { server.asked.value == [10] })
        server.answer(EventsPage(events: [ShellFixtures.event(seq: 11)], nextAfterSeq: 11))
        #expect(await ShellFixtures.eventually { server.asked.value == [10, 11] })

        // A second screen's read stood at 4: it may have missed 5 to 11. The
        // poll that is out is ended and asked again from 4, not waited for.
        feed.noteRead(asOfSeq: 4)
        #expect(await ShellFixtures.eventually { server.asked.value.suffix(1) == [4] })
        server.answer(EventsPage(events: (5...11).map(ShellFixtures.event(seq:)), nextAfterSeq: 11))

        #expect(await ShellFixtures.eventually { seen.value.count == 2 })
        #expect(seen.value.last == Array(5...11))
        subscription.cancel()
        feed.stop()
    }

    @Test("a read that stood higher than where the feed is does not move it forward")
    func higherReadIgnored() async {
        let (feed, _, server) = makeFeed()
        feed.noteRead(asOfSeq: 2)
        #expect(await ShellFixtures.eventually { server.asked.value == [2] })
        feed.noteRead(asOfSeq: 50)
        server.answer(EventsPage(events: [ShellFixtures.event(seq: 3)], nextAfterSeq: 3))
        #expect(await ShellFixtures.eventually { server.asked.value == [2, 3] })
        feed.stop()
    }

    @Test("when the server cannot be reached it says so, asks again from the same place, and recovers")
    func reconnects() async {
        let (feed, _, server) = makeFeed()
        let seen = Locked<[[Int]]>([])
        let subscription = feed.subscribe { events in seen.update { $0.append(events.map(\.seq)) } }

        feed.noteRead(asOfSeq: 20)
        #expect(await ShellFixtures.eventually { server.asked.value == [20] })
        server.fail()
        #expect(await ShellFixtures.eventually { feed.connection == .unreachable })
        #expect(await ShellFixtures.eventually { server.asked.value == [20, 20] })

        server.answer(EventsPage(events: [ShellFixtures.event(seq: 21)], nextAfterSeq: 21))
        #expect(await ShellFixtures.eventually { feed.connection == .live })
        #expect(seen.value == [[21]])
        subscription.cancel()
        feed.stop()
    }

    @Test("every subscriber hears each batch; a cancelled one hears no more")
    func subscribers() async {
        let (feed, _, server) = makeFeed()
        let first = Locked(0)
        let second = Locked(0)
        let one = feed.subscribe { _ in first.update { $0 += 1 } }
        let two = feed.subscribe { _ in second.update { $0 += 1 } }

        feed.noteRead(asOfSeq: 0)
        #expect(await ShellFixtures.eventually { server.asked.value.count == 1 })
        server.answer(EventsPage(events: [ShellFixtures.event(seq: 1)], nextAfterSeq: 1))
        #expect(await ShellFixtures.eventually { first.value == 1 && second.value == 1 })

        one.cancel()
        #expect(await ShellFixtures.eventually { server.asked.value.count == 2 })
        server.answer(EventsPage(events: [ShellFixtures.event(seq: 2)], nextAfterSeq: 2))
        #expect(await ShellFixtures.eventually { second.value == 2 })
        #expect(first.value == 1)
        two.cancel()
        feed.stop()
    }

    @Test("after stop it asks for nothing more, and a later read starts it again")
    func stopAndRestart() async {
        let (feed, owner, server) = makeFeed()
        feed.noteRead(asOfSeq: 1)
        #expect(await ShellFixtures.eventually { server.asked.value == [1] })

        feed.stop()
        let afterStop = owner.calls.count
        server.answer(EventsPage(events: [ShellFixtures.event(seq: 2)], nextAfterSeq: 2))
        try? await Task.sleep(for: .milliseconds(40))
        #expect(owner.calls.count == afterStop)
        #expect(feed.connection == .idle)

        feed.noteRead(asOfSeq: 5)
        // (An answer queued before the restart may be read first; the ask itself is what counts.)
        #expect(await ShellFixtures.eventually { server.asked.value.contains(5) })
        feed.stop()
    }

    @Test("a session that ended during the poll stops it instead of asking again")
    func unauthenticatedStops() async {
        let owner = FakeOwnerAPI()
        owner.script { $0.events = { _, _, _ in throw ShellFixtures.unauthenticated() } }
        let feed = EventFeed(owner: owner, waitSeconds: 25, retryDelay: .milliseconds(5))
        feed.noteRead(asOfSeq: 0)
        #expect(await ShellFixtures.eventually { owner.calls.count >= 1 })
        try? await Task.sleep(for: .milliseconds(40))
        #expect(owner.calls.count == 1)
        #expect(feed.connection == .idle)
    }
}
