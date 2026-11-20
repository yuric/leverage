import Foundation
import LeverageKit
import Observation

/// Tells the owner each time a Needs you item opens, and keeps the count on
/// the Needs you tab (HM-27 to HM-31).
///
/// It keeps a cursor, the highest `inbox.opened` position it announced, in
/// the cursor store, so that it outlives the app (HM-29). At start it checks
/// that the cursor is of this log (a restore or a lost volume makes another
/// one, whose positions start lower) and otherwise starts again from 0. It reads
/// the open items: each above the cursor is announced, and with no stored
/// cursor every open item is. While the app runs it long-polls `list_inbox`
/// from the cursor, and is handed the events of the shared tail: an
/// `inbox.opened` above the cursor whose item the read no longer returns
/// opened and was settled between two looks, and is announced once from the
/// event. The cursor moves only after the notification is handed over.
@MainActor
@Observable
final class InboxWatcher {
    enum Permission: Equatable, Sendable { case unknown, given, notGiven }

    /// How many items are open.
    private(set) var openCount = 0
    private(set) var permission: Permission = .unknown

    /// The line the Needs you screen carries when notifications are off (HM-28).
    var notificationsAreOff: Bool { permission == .notGiven }

    @ObservationIgnored private let owner: any OwnerAPI
    @ObservationIgnored private let notifier: any Notifying
    @ObservationIgnored private let store: any InboxCursorStoring
    @ObservationIgnored private let select: @MainActor () -> Void
    @ObservationIgnored private let waitSeconds: Int
    @ObservationIgnored private let idleDelay: Duration
    @ObservationIgnored private let retryDelay: Duration
    @ObservationIgnored private let log = Log(component: "inbox")
    @ObservationIgnored private var cursor: Int?
    @ObservationIgnored private var announced: Set<UUID> = []
    @ObservationIgnored private var asked = false
    @ObservationIgnored private var chain: Task<Void, Never>?
    @ObservationIgnored private var subscription: EventFeed.Subscription?

    init(
        owner: any OwnerAPI, notifier: any Notifying, cursor: any InboxCursorStoring,
        select: @escaping @MainActor () -> Void, waitSeconds: Int = 25, idleDelay: Duration = .milliseconds(500),
        retryDelay: Duration = .seconds(2)
    ) {
        self.owner = owner
        self.notifier = notifier
        self.store = cursor
        self.select = select
        self.waitSeconds = waitSeconds
        self.idleDelay = idleDelay
        self.retryDelay = retryDelay
    }

    // MARK: the loop

    /// Asks for permission once, reads the inbox, then waits for new items
    /// until the task is cancelled. A click on a notification opens the
    /// Needs you tab while it runs.
    func run() async {
        let select = select
        notifier.onClick { _ in Task { @MainActor in select() } }
        defer { notifier.onClick(nil) }
        await start()
        while !Task.isCancelled {
            let ok = await waitForNewItems()
            if Task.isCancelled { return }
            switch ok {
            case .ended: return
            case .news:
                if await !catchUp() { try? await Task.sleep(for: retryDelay) }
            case .nothing: try? await Task.sleep(for: idleDelay)
            case .failed: try? await Task.sleep(for: retryDelay)
            }
        }
    }

    private enum Wait { case news, nothing, failed, ended }

    private func waitForNewItems() async -> Wait {
        do {
            let page = try await owner.listInbox(afterSeq: currentCursor(), wait: waitSeconds)
            return page.items.isEmpty ? .nothing : .news
        } catch is CancellationError {
            return .ended
        } catch let error as URLError where error.code == .cancelled {
            return .ended
        } catch let error as TransportError where error.code == .unauthenticated {
            // The session ended; the app returns to Sign in.
            return .ended
        } catch {
            return .failed
        }
    }

    /// Asks for permission, once, checks the stored cursor against the log,
    /// and reads the inbox.
    func start() async {
        if !asked {
            asked = true
            permission = await notifier.requestPermission() ? .given : .notGiven
        }
        await checkStoredCursor()
        await catchUp()
    }

    /// The stored cursor is the position of an `inbox.opened` this watcher
    /// announced. After a restore or a lost volume the log is another one,
    /// whose positions start lower, so a new item would sit below the cursor
    /// and never be announced. A cursor the log has no event at or after,
    /// or whose own position holds another kind of event, is of another log:
    /// it goes back to 0, so every open item is announced. A log that
    /// cannot be read keeps the cursor as it is.
    private func checkStoredCursor() async {
        let stored = currentCursor()
        guard stored > 0 else { return }
        let page: EventsPage
        do {
            page = try await owner.events(afterSeq: stored - 1, limit: 1, wait: nil)
        } catch {
            return
        }
        if let first = page.events.first, first.seq != stored || first.type == .inboxOpened { return }
        log.info("the stored inbox cursor is not of this log; every open item is announced")
        cursor = 0
        do {
            try store.save(0)
        } catch {
            log.warning("the inbox cursor could not be kept: \(error.localizedDescription)")
        }
    }

    /// Shows the shared tail's inbox events to the watcher.
    func attach(to feed: EventFeed) {
        subscription?.cancel()
        subscription = feed.subscribe { [weak self] events in
            Task { await self?.handle(events: events) }
        }
    }

    func detach() {
        subscription?.cancel()
        subscription = nil
    }

    // MARK: looking

    /// Reads every open item, sets the count, and announces each one above the
    /// cursor that was not announced yet.
    @discardableResult
    func catchUp() async -> Bool { await serially { await self.look(events: []) } }

    /// An inbox event reads the open items again; an `inbox.opened` above the
    /// cursor whose item the read does not return is announced from the event.
    func handle(events: [EventRecord]) async {
        let relevant = events.filter { $0.type == .inboxOpened || $0.type == .inboxResolved }
        guard !relevant.isEmpty else { return }
        _ = await serially { await self.look(events: relevant) }
    }

    private func currentCursor() -> Int {
        if let cursor { return cursor }
        let loaded = store.load()
        cursor = loaded
        return loaded
    }

    /// One look at a time: two looks at once would announce an item twice.
    private func serially(_ work: @escaping @MainActor () async -> Bool) async -> Bool {
        let previous = chain
        let next = Task { @MainActor () -> Bool in
            await previous?.value
            return await work()
        }
        chain = Task { _ = await next.value }
        return await next.value
    }

    private struct Announcement {
        let seq: Int
        let id: UUID
        let title: String
        let body: String
    }

    private func look(events: [EventRecord]) async -> Bool {
        let items: [InboxItem]
        do {
            items = try await owner.listInbox(afterSeq: nil, wait: nil).items.filter { $0.state == .open }
        } catch {
            if !(error is CancellationError) { log.warning("the inbox could not be read: \(error.localizedDescription)") }
            return false
        }
        openCount = items.count
        if await notifier.isPermitted() { permission = .given } else if asked { permission = .notGiven }

        let above = currentCursor()
        let fresh = items.filter { $0.openedSeq > above && !announced.contains($0.id) }
        let open = Set(items.map(\.id))
        let settled = events.filter {
            guard $0.type == .inboxOpened, $0.seq > above, let id = $0.subjectID else { return false }
            return !open.contains(id) && !announced.contains(id)
        }
        guard !fresh.isEmpty || !settled.isEmpty else { return true }

        let names = await ((try? await NeedsYouNames.read(from: owner).names) ?? NeedsYouNames())
            .checkingOrchestrator(for: fresh, from: owner)
        var pending: [Announcement] = fresh.map {
            Announcement(
                seq: $0.openedSeq, id: $0.id, title: NeedsYouWords.heading(for: $0, names: names),
                body: NeedsYouWords.body(for: $0, names: names))
        }
        for event in settled {
            guard let id = event.subjectID else { continue }
            let kind = event.payload["kind"]?.stringValue.flatMap(NeedsYouItem.init(rawValue:))
            pending.append(
                Announcement(
                    seq: event.seq, id: id, title: NeedsYouWords.settledHeading(kind: kind),
                    body: "\(names.taskTitle(event.taskID)). \(NeedsYouCopy.settledBeforeYouSaw.text)"))
        }
        for one in pending.sorted(by: { $0.seq < $1.seq }) {
            guard !announced.contains(one.id) else { continue }
            await notifier.post(OwnerNotification(itemID: one.id, title: one.title, body: one.body))
            announced.insert(one.id)
            // The cursor moves after the notification was handed over.
            let next = max(cursor ?? 0, one.seq)
            cursor = next
            do {
                try store.save(next)
            } catch {
                log.warning("the inbox cursor could not be kept: \(error.localizedDescription)")
            }
        }
        return true
    }
}
