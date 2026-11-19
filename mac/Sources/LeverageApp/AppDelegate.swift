import AppKit

/// What the window's life needs from AppKit (PK-8): closing the window leaves
/// the app, the helper and the agents running; the Dock icon opens the window
/// again; and quitting stops the helper first and waits for it.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Opens the main window; the scene sets it once the window has appeared.
    var openMainWindow: (@MainActor () -> Void)?
    /// What to finish before the app quits (stopping the helper); nil when
    /// there is nothing to wait for.
    var terminationWork: (@MainActor () async -> Void)?
    /// How the delegate tells AppKit that the app may quit now.
    var replyToTermination: @MainActor (Bool) -> Void = { allow in
        NSApplication.shared.reply(toApplicationShouldTerminate: allow)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openMainWindow?() }
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let work = terminationWork else { return .terminateNow }
        Task { @MainActor in
            await work()
            replyToTermination(true)
        }
        return .terminateLater
    }
}
