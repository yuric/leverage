import SwiftUI

/// The floating left pane: the brand, the three tabs, and the health line at
/// its foot.
struct SidePane: View {
    let context: ScreenContext

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                AppIconView(size: 24)
                Text(ShellCopy.appName.text)
                    .font(.system(size: Tokens.FontSize.head, weight: .bold))
            }
            .padding(.horizontal, 6)

            VStack(spacing: 2) {
                tab(.board, ShellCopy.tabBoard, symbol: "square.grid.3x1.below.line.grid.1x2")
                tab(.needsYou, ShellCopy.tabNeedsYou, symbol: "bell", badge: Self.badge(for: context.inbox.openCount))
                tab(.agents, ShellCopy.tabAgents, symbol: "person.2")
                tab(.credentials, ShellCopy.tabCredentials, symbol: "key")
                tab(.handoff, ShellCopy.tabHandoff, symbol: "arrow.triangle.swap")
            }

            Spacer(minLength: 0)

            HealthLineView(model: context.health)
                .padding(.horizontal, 6)
                .padding(.bottom, 2)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 12)
        .frame(width: Tokens.sidePaneWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .glass(.nav, radius: Tokens.Radius.window - Tokens.Spacing.window)
        .task { await context.health.run() }
    }

    /// The count on the Needs you tab; nil when nothing is open.
    static func badge(for count: Int) -> String? { count > 0 ? String(count) : nil }

    private func tab(
        _ place: Navigator.Place, _ copy: ShellCopy, symbol: String, badge: String? = nil
    ) -> some View {
        let selected = context.navigator.place == place
        return Button {
            context.navigator.show(place)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .frame(width: 16)
                Text(copy.text)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let badge {
                    Text(verbatim: badge)
                        .font(.system(size: Tokens.FontSize.badge, weight: .bold))
                        .padding(.horizontal, 6)
                        .frame(minWidth: 18, minHeight: 18)
                        .foregroundStyle(Tokens.Tone.wait.foreground)
                        .background(Tokens.Tone.wait.background, in: Capsule())
                }
            }
            .font(.system(size: Tokens.FontSize.body, weight: selected ? .semibold : .medium))
            .padding(.horizontal, 8)
            .frame(minHeight: 32)
            .foregroundStyle(selected ? Tokens.Palette.tabOnForeground : Tokens.Palette.tabForeground)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: Tokens.Radius.control, style: .continuous)
                        .fill(Tokens.Palette.tabOnBackground)
                        .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The dot and the sentence at the foot of the pane, with Try again once the
/// helper has given up.
struct HealthLineView: View {
    let model: HealthLineModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 8, height: 8)
                Text(model.sentence.text)
                    .font(.system(size: Tokens.FontSize.small))
                    .foregroundStyle(Tokens.Palette.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.offersTryAgain {
                Button(ShellCopy.tryAgain.text) {
                    Task { await model.tryAgain() }
                }
                .font(.system(size: Tokens.FontSize.small, weight: .semibold))
                .buttonStyle(.link)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var dotColor: Color {
        switch model.tone {
        case .neutral: Tokens.Palette.field
        case .good: Tokens.Palette.ok
        case .warning: Tokens.Tone.wait.foreground
        case .bad: Tokens.Tone.stop.foreground
        }
    }
}
