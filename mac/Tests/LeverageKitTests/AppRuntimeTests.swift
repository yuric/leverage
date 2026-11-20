import Foundation
import LeverageTestSupport
import Testing

@testable import LeverageKit

/// The two services the Handoff milestone adds to the app's runtime
/// (HM-27 to HM-31): the notifier and the inbox cursor store, in the forms
/// that need no system service, and the fakes the app's tests use.
@Suite("App runtime: notifier and inbox cursor")
struct AppRuntimeTests {
    private let item = UUID(uuidString: "00000000-0000-4000-8000-0000000000C1")!

    @Test("the notifier that posts nothing is never permitted and keeps nothing")
    func silentNotifier() async {
        let notifier = SilentNotifier()
        #expect(await notifier.isPermitted() == false)
        #expect(await notifier.requestPermission() == false)
        await notifier.post(OwnerNotification(itemID: item, title: "Made-up", body: "Made-up"))
        notifier.onClick { _ in }
        #expect(await notifier.isPermitted() == false)
    }

    @Test("the cursor kept in memory reads 0 until a number is saved, then that number")
    func memoryCursor() throws {
        let cursor = InMemoryInboxCursor()
        #expect(cursor.load() == 0)
        try cursor.save(12)
        #expect(cursor.load() == 12)
        try cursor.save(15)
        #expect(cursor.load() == 15)
        #expect(InMemoryInboxCursor().load() == 0, "a new store starts again")
    }

    @Test("a runtime with no services of its own posts nothing and keeps the cursor in memory")
    func unavailableRuntime() async throws {
        let runtime = UnavailableRuntime()
        #expect(await runtime.notifier.isPermitted() == false)
        #expect(runtime.inboxCursor.load() == 0)
        try runtime.inboxCursor.save(3)
        #expect(runtime.inboxCursor.load() == 3)
        #expect(UnavailableRuntime().inboxCursor.load() == 0, "each runtime has its own cursor")
    }

    @Test("a runtime that names no notifier or cursor store gets the silent and the memory form")
    func defaults() async {
        struct Bare: AppRuntime {
            let server: any ServerSupervising = UnavailableRuntime().server
            let helper: any HelperSupervising = UnavailableRuntime().helper
            let sessions: any SessionStoring = UnavailableRuntime().sessions
        }
        let runtime = Bare()
        #expect(await runtime.notifier.isPermitted() == false)
        #expect(runtime.inboxCursor.load() == 0)
    }

    @Test("the fake runtime hands the app its fake notifier and fake cursor")
    func fakeRuntime() async throws {
        let runtime = FakeAppRuntime()
        runtime.fakeInboxCursor.stored.value = 9
        #expect(runtime.inboxCursor.load() == 9)

        runtime.fakeNotifier.permission.value = false
        #expect(await runtime.notifier.isPermitted() == false)
        #expect(await runtime.notifier.requestPermission() == false)
        #expect(runtime.fakeNotifier.permissionRequests.value == 1)
        let notification = OwnerNotification(itemID: item, title: "Made-up", body: "Made-up body")
        await runtime.notifier.post(notification)
        #expect(runtime.fakeNotifier.posted.value == [notification])
    }

    @Test("a click reaches the handler with the item's id, and only while a handler is set")
    func click() {
        let notifier = FakeNotifier()
        let clicked = Locked<[UUID]>([])
        #expect(notifier.click(item) == false)
        notifier.onClick { id in clicked.update { $0.append(id) } }
        #expect(notifier.click(item))
        #expect(clicked.value == [item])
        notifier.onClick(nil)
        #expect(notifier.click(item) == false)
        #expect(clicked.value == [item])
    }

    @Test("the fake cursor keeps what was saved, and a failed save keeps nothing and says so")
    func fakeCursor() throws {
        struct Refused: Error {}
        let cursor = FakeInboxCursorStore(stored: 4)
        #expect(cursor.load() == 4)
        try cursor.save(6)
        cursor.failure.value = Refused()
        #expect(throws: Refused.self) { try cursor.save(8) }
        #expect(cursor.load() == 6)
        #expect(cursor.saves.value == [6, 8])
    }
}
