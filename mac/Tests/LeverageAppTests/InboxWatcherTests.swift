import Foundation
import LeverageKit
import LeverageTestSupport
import Testing

@testable import LeverageApp

private typealias Fixtures = NeedsYouFixtures

/// A notifier that notes what the cursor held at the moment each notification
/// was handed over: the cursor moves only after that (HM-29).
private final class OrderRecordingNotifier: Notifying, @unchecked Sendable {
    let cursor: FakeInboxCursorStore
    let heldAtPost = Locked<[Int]>([])
    let posted = Locked<[OwnerNotification]>([])

    init(cursor: FakeInboxCursorStore) { self.cursor = cursor }

    func requestPermission() async -> Bool { true }
    func isPermitted() async -> Bool { true }
    func post(_ notification: OwnerNotification) async {
        heldAtPost.update { $0.append(cursor.stored.value) }
        posted.update { $0.append(notification) }
    }
    func onClick(_ handler: (@Sendable (UUID) -> Void)?) {}
}

@MainActor
@Suite("InboxWatcher")
struct InboxWatcherTests {
    private struct Rig {
        let owner: FakeOwnerAPI
        let open: Locked<[InboxItem]>
        let notifier: FakeNotifier
        let cursor: FakeInboxCursorStore
        let watcher: InboxWatcher
    }

    private func makeRig(
        open items: [InboxItem] = [], stored: Int = 0, wait: Int = 1, owner custom: FakeOwnerAPI? = nil
    ) -> Rig {
        let open = Locked(items)
        let owner = custom ?? Fixtures.owner(open: open)
        let notifier = FakeNotifier()
        let cursor = FakeInboxCursorStore(stored: stored)
        let watcher = InboxWatcher(
            owner: owner, notifier: notifier, cursor: cursor, select: {}, waitSeconds: wait,
            idleDelay: .milliseconds(2), retryDelay: .milliseconds(2))
        return Rig(owner: owner, open: open, notifier: notifier, cursor: cursor, watcher: watcher)
    }

    // MARK: at start

    @Test("at start, with a stored cursor, an open item above it is announced and one at or below it is not")
    func startWithCursor() async {
        let rig = makeRig(
            open: [Fixtures.signedOut(seq: 4), Fixtures.limit(seq: 5), Fixtures.pastRound(seq: 6)], stored: 5)
        await rig.watcher.start()
        #expect(rig.notifier.posted.value.count == 1)
        #expect(rig.notifier.posted.value.first?.title == "Fix the totals on the invoice page was sent back 3 times")
        #expect(rig.cursor.stored.value == 6)
        #expect(rig.watcher.openCount == 3)
    }

    // Review: the cursor is kept in the support folder, the log in the
    // database. After a restore or a lost volume the log's positions start
    // lower than the stored cursor, and every new item would sit below it.

    @Test("a stored cursor above every position of the log is of another log: every open item is announced")
    func cursorAboveTheLog() async {
        let rig = makeRig(open: [Fixtures.signedOut(seq: 5)], stored: 100)
        await rig.watcher.start()
        #expect(rig.notifier.posted.value.map(\.title) == ["Claude, Personal is signed out"])
        #expect(rig.cursor.stored.value == 5)
    }

    @Test("a stored cursor whose position holds another kind of event is of another log too")
    func cursorOnAnotherEvent() async {
        let open = Locked([Fixtures.signedOut(seq: 3)])
        let owner = Fixtures.owner(open: open)
        owner.script {
            $0.events = { after, _, _ in
                let event = TaskScreenFixtures.event(.taskCreated, seq: 7, taskID: Fixtures.taskID, actorKind: .owner)
                return EventsPage(events: after < 7 ? [event] : [], nextAfterSeq: after < 7 ? 7 : after)
            }
        }
        let rig = makeRig(open: [Fixtures.signedOut(seq: 3)], stored: 7, owner: owner)
        await rig.watcher.start()
        #expect(rig.notifier.posted.value.count == 1)
        #expect(rig.cursor.stored.value == 3)
    }

    @Test("a cursor that cannot be checked is kept as it is")
    func cursorUnchecked() async {
        let open = Locked([Fixtures.signedOut(seq: 4)])
        let owner = Fixtures.owner(open: open)
        owner.script { $0.events = { _, _, _ in throw URLError(.timedOut) } }
        let rig = makeRig(open: [Fixtures.signedOut(seq: 4)], stored: 5, owner: owner)
        await rig.watcher.start()
        #expect(rig.notifier.posted.value.isEmpty)
        #expect(rig.cursor.stored.value == 5)
    }

    @Test("with no stored cursor every open item is announced, in the order they opened")
    func startWithNoCursor() async {
        let rig = makeRig(open: [Fixtures.pastRound(seq: 9), Fixtures.signedOut(seq: 3), Fixtures.limit(seq: 5)])
        await rig.watcher.start()
        #expect(rig.notifier.posted.value.map(\.title) == [
            "Claude, Personal is signed out", "Claude, Personal is at its limit",
            "Fix the totals on the invoice page was sent back 3 times",
        ])
        #expect(rig.cursor.saves.value == [3, 5, 9])
    }

    @Test("a notification carries the heading, the task's title and the account's name, and never an email")
    func notificationWords() async {
        let rig = makeRig(open: [Fixtures.signedOut(seq: 3)])
        await rig.watcher.start()
        let note = rig.notifier.posted.value.first
        #expect(note?.title == "Claude, Personal is signed out")
        #expect(note?.body.contains("Fix the totals on the invoice page") == true)
        #expect(note?.body.contains("Claude, Personal") == true)
        for text in [note?.title, note?.body] {
            #expect(text?.contains(Fixtures.madeUpEmail) == false)
            #expect(text?.contains("@") == false)
        }
    }

    @Test("an item whose names cannot be read is still announced, with plain fallbacks")
    func namesFail() async {
        let open = Locked([Fixtures.signedOut(seq: 3)])
        let owner = Fixtures.owner(open: open)
        owner.script { $0.board = { throw URLError(.timedOut) } }
        let rig = makeRig(open: [Fixtures.signedOut(seq: 3)], owner: owner)
        await rig.watcher.start()
        #expect(rig.notifier.posted.value.map(\.title) == ["An account is signed out"])
    }

    @Test("the cursor moves only after the notification is handed over")
    func cursorAfterPost() async {
        let cursor = FakeInboxCursorStore(stored: 2)
        let notifier = OrderRecordingNotifier(cursor: cursor)
        let open = Locked([Fixtures.signedOut(seq: 3), Fixtures.limit(seq: 4)])
        let watcher = InboxWatcher(
            owner: Fixtures.owner(open: open), notifier: notifier, cursor: cursor, select: {}, waitSeconds: 1,
            idleDelay: .milliseconds(2), retryDelay: .milliseconds(2))
        await watcher.start()
        #expect(notifier.heldAtPost.value == [2, 3])
        #expect(cursor.stored.value == 4)
    }

    @Test("an item is announced once, however often the inbox is read again")
    func announcedOnce() async {
        let rig = makeRig(open: [Fixtures.signedOut(seq: 3)])
        await rig.watcher.start()
        await rig.watcher.catchUp()
        await rig.watcher.catchUp()
        #expect(rig.notifier.posted.value.count == 1)
    }

    @Test("a cursor that cannot be saved does not announce an item twice")
    func saveFails() async {
        let rig = makeRig(open: [Fixtures.signedOut(seq: 3)])
        rig.cursor.failure.value = URLError(.cannotWriteToFile)
        await rig.watcher.start()
        await rig.watcher.catchUp()
        #expect(rig.notifier.posted.value.count == 1)
    }

    @Test("no item is announced twice across a restart")
    func acrossRestart() async {
        let open = Locked([Fixtures.signedOut(seq: 3), Fixtures.limit(seq: 4)])
        let cursor = FakeInboxCursorStore()
        let first = FakeNotifier()
        let second = FakeNotifier()
        let owner = Fixtures.owner(open: open)
        let a = InboxWatcher(
            owner: owner, notifier: first, cursor: cursor, select: {}, waitSeconds: 1, idleDelay: .milliseconds(2),
            retryDelay: .milliseconds(2))
        await a.start()
        let b = InboxWatcher(
            owner: owner, notifier: second, cursor: cursor, select: {}, waitSeconds: 1, idleDelay: .milliseconds(2),
            retryDelay: .milliseconds(2))
        await b.start()
        #expect(first.posted.value.count == 2)
        #expect(second.posted.value.isEmpty)
        open.update { $0.append(Fixtures.pastRound(seq: 8)) }
        await b.catchUp()
        #expect(second.posted.value.count == 1)
    }

    // MARK: while running

    @Test("a new item while running posts one notification, and the cursor is stored after it")
    func newItemWhileRunning() async {
        let rig = makeRig()
        let run = Task { await rig.watcher.run() }
        #expect(await ShellFixtures.eventually { rig.notifier.permissionRequests.value == 1 })
        rig.open.update { $0.append(Fixtures.signedOut(seq: 12)) }
        #expect(await ShellFixtures.eventually { rig.notifier.posted.value.count == 1 })
        #expect(await ShellFixtures.eventually { rig.cursor.stored.value == 12 })
        #expect(rig.notifier.posted.value.first?.title == "Claude, Personal is signed out")
        #expect(rig.watcher.openCount == 1)
        run.cancel()
        await run.value
        #expect(rig.notifier.posted.value.count == 1)
    }

    @Test("the long poll asks from the cursor, and waits")
    func longPollAsksFromCursor() async {
        let asked = Locked<[(Int?, Int?)]>([])
        let owner = Fixtures.owner(open: Locked([]))
        owner.script {
            $0.listInbox = { after, wait in
                asked.update { $0.append((after, wait)) }
                return Fixtures.page([])
            }
            // The log holds the cursor's own inbox.opened, so the cursor is of it.
            $0.events = { after, _, _ in
                let opened = Fixtures.opened(seq: 7, item: UUID(), kind: .accountSignedOut)
                return EventsPage(events: after < 7 ? [opened] : [], nextAfterSeq: max(after, 7))
            }
        }
        let rig = makeRig(stored: 7, wait: 20, owner: owner)
        let run = Task { await rig.watcher.run() }
        #expect(await ShellFixtures.eventually { asked.value.contains { $0.1 == 20 } })
        run.cancel()
        await run.value
        let polls = asked.value.filter { $0.1 != nil }
        #expect(polls.allSatisfy { $0.0 == 7 && $0.1 == 20 })
    }

    @Test("the loop ends with the task, and the click handler is removed")
    func loopEnds() async {
        let rig = makeRig()
        let run = Task { await rig.watcher.run() }
        #expect(await ShellFixtures.eventually { rig.notifier.permissionRequests.value == 1 })
        run.cancel()
        await run.value
        #expect(rig.notifier.click(UUID()) == false)
    }

    @Test("a 401 ends the loop quietly")
    func unauthenticated() async {
        let owner = Fixtures.owner(open: Locked([]))
        owner.script { $0.listInbox = { _, _ in throw ShellFixtures.unauthenticated() } }
        let rig = makeRig(owner: owner)
        await rig.watcher.run()
        #expect(rig.notifier.posted.value.isEmpty)
    }

    // MARK: settled before the app looked

    @Test("an opened event above the cursor whose item the read no longer returns is announced once, from the event")
    func settledBeforeSeen() async {
        let rig = makeRig(stored: 5)
        let item = UUID()
        let event = Fixtures.opened(seq: 9, item: item, kind: .pastRoundLimit)
        await rig.watcher.handle(events: [event])
        await rig.watcher.handle(events: [event])
        #expect(rig.notifier.posted.value.count == 1)
        let note = rig.notifier.posted.value.first
        #expect(note?.itemID == item)
        #expect(note?.title == "Sent back too many times")
        #expect(note?.body == "Fix the totals on the invoice page. This was settled before you saw it.")
        #expect(rig.cursor.stored.value == 9)
    }

    @Test("an opened event whose item the read does return is announced once, as the item")
    func eventAndItem() async {
        let id = UUID()
        let rig = makeRig(open: [Fixtures.signedOut(seq: 9, id: id)], stored: 5)
        await rig.watcher.handle(events: [Fixtures.opened(seq: 9, item: id, kind: .accountSignedOut)])
        await rig.watcher.start()
        #expect(rig.notifier.posted.value.count == 1)
        #expect(rig.notifier.posted.value.first?.title == "Claude, Personal is signed out")
    }

    @Test("an opened event at or below the cursor announces nothing")
    func eventBelowCursor() async {
        let rig = makeRig(stored: 9)
        await rig.watcher.handle(events: [Fixtures.opened(seq: 9, item: UUID(), kind: .accountSignedOut)])
        #expect(rig.notifier.posted.value.isEmpty)
    }

    @Test("events that are not about the inbox read nothing")
    func otherEvents() async {
        let rig = makeRig()
        await rig.watcher.handle(events: [ShellFixtures.event(seq: 3)])
        #expect(rig.owner.calls.isEmpty)
    }

    // MARK: the count

    @Test("a resolved item lowers the count")
    func resolvedLowersCount() async {
        let first = UUID()
        let rig = makeRig(open: [Fixtures.signedOut(seq: 3, id: first), Fixtures.limit(seq: 4)])
        await rig.watcher.start()
        #expect(rig.watcher.openCount == 2)
        rig.open.value = rig.open.value.filter { $0.id != first }
        await rig.watcher.handle(events: [Fixtures.resolved(seq: 10, item: first)])
        #expect(rig.watcher.openCount == 1)
    }

    @Test("an event from the feed reads again, and a new item is announced")
    func feedEvents() async {
        let rig = makeRig()
        let batches = Locked<[EventsPage]>([])
        rig.owner.script {
            $0.events = { _, _, _ in
                while true {
                    if let page = batches.update({ $0.isEmpty ? nil : $0.removeFirst() }) { return page }
                    try await Task.sleep(for: .milliseconds(2))
                }
            }
        }
        let feed = EventFeed(owner: rig.owner, waitSeconds: 25, retryDelay: .milliseconds(5))
        rig.watcher.attach(to: feed)
        feed.noteRead(asOfSeq: 1)
        let id = UUID()
        rig.open.update { $0.append(Fixtures.signedOut(seq: 20, id: id)) }
        batches.update { $0.append(EventsPage(events: [Fixtures.opened(seq: 20, item: id, kind: .accountSignedOut)], nextAfterSeq: 20)) }
        #expect(await ShellFixtures.eventually { rig.notifier.posted.value.count == 1 })
        #expect(rig.watcher.openCount == 1)
        feed.stop()
    }

    // MARK: permission (HM-28)

    @Test("permission is asked for once, at start; given, the screen carries no line")
    func permissionGiven() async {
        let rig = makeRig()
        await rig.watcher.start()
        #expect(rig.notifier.permissionRequests.value == 1)
        #expect(rig.watcher.permission == .given)
        #expect(!rig.watcher.notificationsAreOff)
    }

    @Test("when permission is not given, the line says notifications are off")
    func permissionRefused() async {
        let rig = makeRig(open: [Fixtures.signedOut(seq: 3)])
        rig.notifier.permission.value = false
        await rig.watcher.start()
        #expect(rig.watcher.permission == .notGiven)
        #expect(rig.watcher.notificationsAreOff)
        #expect(rig.watcher.openCount == 1)
        #expect(
            NeedsYouCopy.notificationsOff.text
                == "Notifications are off for Leverage. Turn them on in System Settings to be told when something needs you.")
    }

    @Test("before anything is asked the line is not shown")
    func permissionUnknown() {
        #expect(!makeRig().watcher.notificationsAreOff)
    }

    // MARK: the click and the tab

    @Test("a click on a notification selects the Needs you tab")
    func clickSelectsTab() async throws {
        let shell = ShellRig()
        shell.scriptSignIn(ownerExists: true)
        let open = Locked([Fixtures.signedOut(seq: 3)])
        shell.owner.script {
            $0.board = { Fixtures.board() }
            $0.credentials = { Fixtures.credentials() }
            $0.listInbox = { after, _ in Fixtures.page(open.value.filter { $0.openedSeq > (after ?? 0) }) }
        }
        shell.runtime.fakeSessions.token.value = "stored-made-up-token"
        let model = shell.makeModel()
        await model.start()
        let context = try #require(model.screens)
        let run = Task { await context.startInbox() }
        #expect(await ShellFixtures.eventually { shell.runtime.fakeNotifier.posted.value.count == 1 })
        #expect(context.navigator.place == .board)
        let posted = try #require(shell.runtime.fakeNotifier.posted.value.first)
        #expect(shell.runtime.fakeNotifier.click(posted.itemID))
        #expect(await ShellFixtures.eventually { context.navigator.place == .needsYou })
        #expect(context.inbox.openCount == 1)
        run.cancel()
        await run.value
    }
}
