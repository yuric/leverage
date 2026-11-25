import AppKit
import SwiftUI

struct AccountMenu: View {
    let context: ScreenContext
    let settingsAreOpen: Bool
    let signOut: @MainActor () async -> Void

    @Environment(\.openSettings) private var openSettings
    @State private var anchor = AccountMenuAnchor()

    var body: some View {
        Button(action: showMenu) {
            HStack(spacing: 8) {
                avatar
                    .accessibilityHidden(true)
                Text(verbatim: context.ownerEmail ?? ShellCopy.account.text)
                    .font(.system(size: Tokens.FontSize.body, weight: .semibold))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: Tokens.FontSize.small))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 8)
            .frame(minHeight: 44)
            .foregroundStyle(settingsAreOpen ? Tokens.Palette.tabOnForeground : Tokens.Palette.tabForeground)
            .background {
                if settingsAreOpen {
                    RoundedRectangle(cornerRadius: Tokens.Radius.control)
                        .fill(Tokens.Palette.tabOnBackground)
                        .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background { AccountMenuAttachment(anchor: anchor).accessibilityHidden(true) }
        .onKeyPress(keys: [.return, .space], phases: .down) { _ in
            showMenu()
            return .handled
        }
        .accessibilityLabel(ShellCopy.accountMenu.text)
        .accessibilityValue(Text(verbatim: context.ownerEmail ?? ""))
        .accessibilityAddTraits(settingsAreOpen ? .isSelected : [])
        .onChange(of: context.ownerEmail) { _, email in
            anchor.updateTitle(email ?? ShellCopy.account.text)
        }
    }

    private var avatar: some View {
        ZStack {
            Circle().fill(Tokens.Tone.info.background)
            if let first = context.ownerEmail?.first {
                Text(verbatim: String(first).uppercased())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            } else {
                Image(systemName: "person")
            }
        }
        .font(.system(size: Tokens.FontSize.small, weight: .bold))
        .foregroundStyle(Tokens.Tone.info.foreground)
        .frame(width: 24, height: 24)
    }

    private func showMenu() {
        if context.ownerEmail == nil {
            Task { await context.loadOwnerIdentity() }
        }
        switch anchor.showMenu(title: context.ownerEmail ?? ShellCopy.account.text) {
        case .settings: openSettings()
        case .signOut: Task { await signOut() }
        case nil: break
        }
    }
}

// An inert AppKit view pins the system menu above the SwiftUI button.
// AppKit handles menu tracking, including arrows, Return and cancellation.
private struct AccountMenuAttachment: NSViewRepresentable {
    let anchor: AccountMenuAnchor

    func makeNSView(context: Context) -> AccountMenuAnchor { anchor }

    func updateNSView(_ view: AccountMenuAnchor, context: Context) {}
}

private final class AccountMenuAnchor: NSView {
    enum Choice { case settings, signOut }

    private var choice: Choice?
    private weak var header: NSMenuItem?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func showMenu(title: String) -> Choice? {
        guard window != nil else { return nil }
        choice = nil
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.minimumWidth = bounds.width
        let heading = NSMenuItem.sectionHeader(title: title)
        header = heading
        menu.addItem(heading)
        defer { header = nil }

        let subscription = NSMenuItem(title: ShellCopy.subscription.text, action: nil, keyEquivalent: "")
        subscription.image = NSImage(systemSymbolName: "creditcard", accessibilityDescription: nil)
        subscription.isEnabled = false
        menu.addItem(subscription)

        let settings = NSMenuItem(title: ShellCopy.settings.text, action: #selector(chooseSettings), keyEquivalent: ",")
        settings.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())
        let signOut = NSMenuItem(title: ShellCopy.signOut.text, action: #selector(chooseSignOut), keyEquivalent: "")
        signOut.image = NSImage(systemSymbolName: "rectangle.portrait.and.arrow.right", accessibilityDescription: nil)
        signOut.target = self
        menu.addItem(signOut)

        let top = NSPoint(x: bounds.minX, y: bounds.maxY + menu.size.height)
        _ = menu.popUp(positioning: nil, at: top, in: self)
        return choice
    }

    func updateTitle(_ title: String) {
        header?.title = title
    }

    @objc private func chooseSettings() { choice = .settings }
    @objc private func chooseSignOut() { choice = .signOut }
}
