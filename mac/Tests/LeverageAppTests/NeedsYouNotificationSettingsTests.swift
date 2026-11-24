import AppKit
import Foundation
import LeverageTestSupport
import Testing

@testable import LeverageApp

@MainActor
@Suite("Needs you notification settings")
struct NeedsYouNotificationSettingsTests {
    @Test("opens the first available settings target in order", arguments: [0, 1, 2, 3])
    func opensFirstAvailable(firstAccepted: Int) {
        let targets = [
            URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=example.leverage")!,
            URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!,
            URL(fileURLWithPath: "/Applications/Example Settings.app"),
        ]
        var attempted: [URL] = []
        var appLookups = 0

        NeedsYouContent.openNotificationSettings(
            bundleIdentifier: "example.leverage",
            openURL: { url in
                attempted.append(url)
                return attempted.count - 1 == firstAccepted
            },
            settingsAppURL: {
                appLookups += 1
                return targets[2]
            })

        #expect(attempted == Array(targets.prefix(firstAccepted + 1)))
        #expect(appLookups == (firstAccepted >= 2 ? 1 : 0))
    }

    @Test("leaves off the bundle query when the app has no bundle ID")
    func noBundleID() {
        var attempted: [String] = []
        NeedsYouContent.openNotificationSettings(
            bundleIdentifier: nil,
            openURL: { url in
                attempted.append(url.absoluteString)
                return false
            },
            settingsAppURL: { nil })

        #expect(attempted == [
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.notifications",
        ])
    }

    @Test("returning to the app refreshes permission even when the inbox cannot be read")
    func refreshesOnActivation() async {
        let owner = NeedsYouFixtures.owner(open: Locked([]))
        let polling = Locked(false)
        owner.script {
            $0.listInbox = { _, wait in
                if wait != nil { polling.value = true }
                throw URLError(.notConnectedToInternet)
            }
        }
        let notifier = FakeNotifier()
        notifier.permission.value = false
        let watcher = InboxWatcher(owner: owner, notifier: notifier, cursor: FakeInboxCursorStore(), select: {})
        let activationCenter = NotificationCenter()
        let run = Task { await watcher.run(activationCenter: activationCenter) }

        let started = await ShellFixtures.eventually(timeout: .seconds(30)) { polling.value }
        #expect(started)
        if started {
            #expect(watcher.permission == .notGiven)
            notifier.permission.value = true
            activationCenter.post(name: NSApplication.didBecomeActiveNotification, object: nil)
            #expect(await ShellFixtures.eventually(timeout: .seconds(30)) { watcher.permission == .given })
            #expect(notifier.permissionRequests.value == 1)
        }

        run.cancel()
        await run.value
    }
}
