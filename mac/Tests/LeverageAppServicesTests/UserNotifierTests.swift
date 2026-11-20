import Foundation
import LeverageKit
import LeverageTestSupport
import Testing

@testable import LeverageAppServices

// These tests never touch the notification center: `make` is given made
// values, and the one case that gets the real type does nothing with it.
@Suite("UserNotifier")
struct UserNotifierTests {
    private let bundle = URL(fileURLWithPath: "/Applications/Leverage.app", isDirectory: true)

    @Test("a path ending in .app with LEVERAGE_NOTIFICATIONS=off gives the form that posts nothing")
    func offInABundle() {
        let notifier = UserNotifier.make(bundleURL: bundle, environment: ["LEVERAGE_NOTIFICATIONS": "off"])
        #expect(notifier is SilentNotifier)
        #expect(!(notifier is UserNotifier))
    }

    @Test("a path that does not end in .app gives it too, with the variable unset")
    func notABundle() {
        for path in ["/Users/someone/project/mac/.build/debug", "/usr/local/bin", "/Applications/Leverage.app/Contents/MacOS", "/tmp/not-an-app"] {
            let notifier = UserNotifier.make(bundleURL: URL(fileURLWithPath: path, isDirectory: true), environment: [:])
            #expect(notifier is SilentNotifier, "\(path)")
        }
    }

    @Test("the test process's own bundle gives it too")
    func theTestProcessItself() {
        let notifier = UserNotifier.make(bundleURL: Bundle.main.bundleURL, environment: [:])
        #expect(notifier is SilentNotifier)
    }

    @Test("a path ending in .app with the variable unset gives the real type")
    func realInABundle() {
        // Made, and never used: making it calls nothing on the center.
        #expect(UserNotifier.make(bundleURL: bundle, environment: [:]) is UserNotifier)
        #expect(UserNotifier.make(bundleURL: URL(fileURLWithPath: "/Applications/Leverage.app"), environment: [:]) is UserNotifier)
        #expect(UserNotifier.make(bundleURL: bundle, environment: ["LEVERAGE_NOTIFICATIONS": "on"]) is UserNotifier)
        #expect(UserNotifier.make(bundleURL: bundle, environment: ["LEVERAGE_NOTIFICATIONS": ""]) is UserNotifier)
    }

    @Test("off is read however it is written")
    func offWrittenOtherWays() {
        for value in ["OFF", "Off", " off ", "off\n"] {
            #expect(UserNotifier.make(bundleURL: bundle, environment: ["LEVERAGE_NOTIFICATIONS": value]) is SilentNotifier, "\(value)")
        }
    }

    @Test("the silent form posts nothing and says permission is not given")
    func silentForm() async {
        let notifier = UserNotifier.make(bundleURL: Bundle.main.bundleURL, environment: [:])
        #expect(await notifier.requestPermission() == false)
        #expect(await notifier.isPermitted() == false)
        await notifier.post(OwnerNotification(itemID: UUID(), title: "t", body: "b"))
    }

    @Test("a notification names its item, and a click reports that item to the handler")
    func clickReportsTheItem() throws {
        let item = UUID()
        let notification = OwnerNotification(itemID: item, title: "A task needs you", body: "Sign in again")
        let info = UserNotifier.userInfo(for: notification)
        #expect(UserNotifier.itemID(from: info) == item)
        #expect(UserNotifier.itemID(from: [:]) == nil)
        #expect(UserNotifier.itemID(from: ["itemID": "not a uuid"]) == nil)
        #expect(UserNotifier.itemID(from: ["itemID": 5]) == nil)

        let notifier = UserNotifier()
        let heard = Locked<[UUID]>([])
        notifier.onClick { id in heard.update { $0.append(id) } }
        notifier.deliverClick(userInfo: info)
        notifier.deliverClick(userInfo: ["itemID": "nothing"])
        #expect(heard.value == [item])

        notifier.onClick(nil)
        notifier.deliverClick(userInfo: info)
        #expect(heard.value == [item])
    }

    @Test("what a notification carries is its item and no more")
    func carriesOnlyTheItem() {
        let item = UUID()
        let info = UserNotifier.userInfo(for: OwnerNotification(itemID: item, title: "T", body: "B"))
        #expect(info.count == 1)
        #expect(info.values.allSatisfy { $0 == item.uuidString })
    }
}
