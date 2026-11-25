import SwiftUI

struct AccountMenu: View {
    let context: ScreenContext
    let settingsAreOpen: Bool
    let signOut: @MainActor () async -> Void

    @Environment(\.openSettings) private var openSettings
    @FocusState private var rowFocused: Bool
    @FocusState private var focusedEntry: Entry?
    @State private var showsMenu = false
    @State private var restoreRowFocus = false

    private enum Entry: Hashable { case settings, signOut }

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
            .foregroundStyle(isHighlighted ? Tokens.Palette.tabOnForeground : Tokens.Palette.tabForeground)
            .background {
                if isHighlighted {
                    RoundedRectangle(cornerRadius: Tokens.Radius.control)
                        .fill(Tokens.Palette.tabOnBackground)
                        .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($rowFocused)
        .onKeyPress(.return) {
            showMenu()
            return .handled
        }
        .accessibilityLabel(ShellCopy.accountMenu.text)
        .accessibilityValue(Text(verbatim: context.ownerEmail ?? ""))
        .accessibilityAddTraits(settingsAreOpen ? .isSelected : [])
        .popover(isPresented: $showsMenu, arrowEdge: .top) { menu }
    }

    private var isHighlighted: Bool { settingsAreOpen || showsMenu }

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

    private var menu: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: context.ownerEmail ?? ShellCopy.account.text)
                .font(.system(size: Tokens.FontSize.body, weight: .semibold))
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
            Divider()

            Button {} label: {
                entryLabel(.subscription, symbol: "creditcard")
                    .foregroundStyle(.tertiary)
            }
            .disabled(true)

            Button(action: showSettings) {
                entryLabel(.settings, symbol: "gearshape", shortcut: "⌘,")
            }
            .focused($focusedEntry, equals: .settings)
            .onKeyPress(.return) {
                showSettings()
                return .handled
            }

            Divider()
            Button(action: endSession) {
                entryLabel(.signOut, symbol: "rectangle.portrait.and.arrow.right")
            }
            .focused($focusedEntry, equals: .signOut)
            .onKeyPress(.return) {
                endSession()
                return .handled
            }
        }
        .buttonStyle(.plain)
        .padding(8)
        .frame(width: 236)
        .defaultFocus($focusedEntry, .settings)
        .onKeyPress(.upArrow) { moveFocus() }
        .onKeyPress(.downArrow) { moveFocus() }
        .onExitCommand {
            restoreRowFocus = true
            showsMenu = false
        }
        .onDisappear {
            guard restoreRowFocus else { return }
            restoreRowFocus = false
            Task { @MainActor in rowFocused = true }
        }
        .task { await context.loadOwnerIdentity() }
    }

    private func entryLabel(_ copy: ShellCopy, symbol: String, shortcut: String? = nil) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .frame(width: 16)
                .accessibilityHidden(true)
            Text(copy.text)
            Spacer(minLength: 0)
            if let shortcut {
                Text(verbatim: shortcut)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 32)
        .contentShape(Rectangle())
    }

    private func showMenu() {
        restoreRowFocus = false
        showsMenu = true
    }

    // Both directions cycle between the enabled entries during this step.
    private func moveFocus() -> KeyPress.Result {
        focusedEntry = focusedEntry == .settings ? .signOut : .settings
        return .handled
    }

    private func showSettings() {
        showsMenu = false
        openSettings()
    }

    private func endSession() {
        showsMenu = false
        Task { await signOut() }
    }
}
