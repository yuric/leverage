import SwiftUI

/// The strip above the content: the tab's title, Back to the board on a
/// task's page, and the Add task button on every tab.
struct Toolbar: View {
    let context: ScreenContext

    var body: some View {
        HStack(spacing: 12) {
            if context.navigator.openTaskID != nil {
                Button {
                    context.navigator.closeTask()
                } label: {
                    Label(ShellCopy.backToBoard.text, systemImage: "chevron.left")
                }
                .buttonStyle(.link)
                .font(.system(size: Tokens.FontSize.body, weight: .semibold))
            }
            Text(title.text)
                .font(.system(size: Tokens.FontSize.head, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(ShellCopy.addTask.text) {
                context.navigator.presentAddTask()
            }
            .buttonStyle(PrimaryButtonStyle())
        }
        .frame(minHeight: 52)
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .padding(.bottom, 4)
    }

    private var title: ShellCopy {
        switch context.navigator.place {
        case .board: ShellCopy.tabBoard
        case .needsYou: ShellCopy.tabNeedsYou
        case .decided: ShellCopy.tabDecided
        case .activity: ShellCopy.tabActivity
        case .agents: ShellCopy.tabAgents
        case .credentials: ShellCopy.tabCredentials
        case .handoff: ShellCopy.tabHandoff
        case .settings: ShellCopy.tabSettings
        case .projects: ShellCopy.projects
        }
    }
}

/// The one raised blue button of a screen.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: Tokens.FontSize.body, weight: .semibold))
            .padding(.horizontal, 16)
            .frame(minHeight: 36)
            .foregroundStyle(Tokens.Palette.primaryForeground)
            .background(
                Tokens.Palette.primary.opacity(configuration.isPressed ? 0.85 : 1),
                in: RoundedRectangle(cornerRadius: Tokens.Radius.control, style: .continuous)
            )
            .shadow(color: Tokens.Palette.primary.opacity(0.32), radius: 8, y: 4)
            .opacity(isEnabled ? 1 : 0.38)
    }
}
