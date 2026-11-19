import Foundation
import LeverageKit
import Observation

/// The one tail of `list_events` that every screen shares (MA-20).
///
/// A screen reads what it shows, then tells the feed where its read stood
/// (`noteRead(asOfSeq:)`, the `as_of_seq` the read carried). The feed
/// long-polls from the lowest position it was given, so no screen can miss an
/// event that happened after its own read, and tells every subscriber about
/// each batch of events. A screen then reads again. Reading again is cheap and
/// idempotent; missing an event is not, so a position that is too low is
/// harmless and one that is too high is never used.
///
/// Nothing is asked of the server until a screen has read once.
@MainActor
@Observable
final class EventFeed {
    enum Connection: Equatable, Sendable {
        /// Not started, or stopped.
        case idle
        /// The last ask was answered.
        case live
        /// The last ask failed; it is asked again.
        case unreachable
    }

    /// A handle to cancel a subscription with.
    @MainActor
    final class Subscription {
        fileprivate let id: UUID
        private weak var feed: EventFeed?

        fileprivate init(id: UUID, feed: EventFeed) {
            self.id = id
            self.feed = feed
        }

        func cancel() { feed?.handlers[id] = nil }
    }

    private(set) var connection: Connection = .idle
    /// Goes up by one for each batch of events delivered; a view can watch it.
    private(set) var revision = 0
    /// The newest batch.
    private(set) var latestEvents: [EventRecord] = []

    @ObservationIgnored private let owner: any OwnerAPI
    @ObservationIgnored private let waitSeconds: Int
    @ObservationIgnored private let retryDelay: Duration
    /// The `after_seq` of the next ask; nil until a screen has read.
    @ObservationIgnored private var cursor: Int?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored fileprivate var handlers: [UUID: @MainActor ([EventRecord]) -> Void] = [:]

    init(owner: any OwnerAPI, waitSeconds: Int = 25, retryDelay: Duration = .seconds(2)) {
        self.owner = owner
        self.waitSeconds = waitSeconds
        self.retryDelay = retryDelay
    }

    /// Tells the feed where a screen's read stood. The first call starts the
    /// tail. A position lower than the feed's own moves it back and asks again
    /// at once, instead of waiting out the long poll that is out.
    func noteRead(asOfSeq seq: Int) {
        if let current = cursor, seq >= current { return }
        cursor = seq
        restart()
    }

    /// Calls `handler`, on the main actor, with each batch of events.
    func subscribe(_ handler: @escaping @MainActor ([EventRecord]) -> Void) -> Subscription {
        let id = UUID()
        handlers[id] = handler
        return Subscription(id: id, feed: self)
    }

    /// Ends the tail. A later `noteRead` starts it again.
    func stop() {
        loop?.cancel()
        loop = nil
        cursor = nil
        connection = .idle
    }

    private func restart() {
        loop?.cancel()
        loop = Task { [weak self] in await self?.tail() }
    }

    private func tail() async {
        while !Task.isCancelled {
            guard let requested = cursor else { return }
            do {
                let page = try await owner.events(afterSeq: requested, limit: 100, wait: waitSeconds)
                if Task.isCancelled { return }
                // A screen moved the feed back while this ask was out: its
                // answer starts from the wrong place. Ask again from the new one.
                guard cursor == requested else { continue }
                connection = .live
                cursor = page.nextAfterSeq
                if !page.events.isEmpty { deliver(page.events) }
            } catch is CancellationError {
                return
            } catch let error as URLError where error.code == .cancelled {
                return
            } catch let error as TransportError where error.code == .unauthenticated {
                // The session ended. The app returns to Sign in; nothing to ask for.
                if !Task.isCancelled { stop() }
                return
            } catch {
                if Task.isCancelled { return }
                connection = .unreachable
                try? await Task.sleep(for: retryDelay)
            }
        }
    }

    private func deliver(_ events: [EventRecord]) {
        latestEvents = events
        revision += 1
        for handler in handlers.values { handler(events) }
    }
}
