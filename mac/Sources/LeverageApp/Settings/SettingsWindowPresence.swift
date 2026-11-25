import AppKit
import SwiftUI

/// Reports the lifetime of the native Settings window even while another
/// window is in front. The sidebar follows actual window state from either
/// the app command or the account menu.
struct SettingsWindowPresence: NSViewRepresentable {
    @Binding var isOpen: Bool

    func makeNSView(context: Context) -> SettingsWindowProbe {
        SettingsWindowProbe()
    }

    func updateNSView(_ view: SettingsWindowProbe, context: Context) {
        view.onChange = { isOpen = $0 }
    }
}

final class SettingsWindowProbe: NSView {
    var onChange: ((Bool) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let notifications = NotificationCenter.default
        notifications.removeObserver(self)
        if let window {
            notifications.addObserver(
                self, selector: #selector(didOpen), name: NSWindow.didBecomeKeyNotification, object: window)
            notifications.addObserver(
                self, selector: #selector(willClose), name: NSWindow.willCloseNotification, object: window)
        }
        // Attaching the AppKit view can run during a SwiftUI update.
        Task { @MainActor [weak self] in
            guard let self else { return }
            onChange?(window?.isVisible == true)
        }
    }

    @objc private func didOpen() { onChange?(true) }
    @objc private func willClose() { onChange?(false) }
}
