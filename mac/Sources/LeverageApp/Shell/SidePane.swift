import LeverageKit
import SwiftUI

/// The floating left pane: tabs, project filters and the health line.
struct SidePane: View {
    let context: ScreenContext
    @State private var projectListAttempt = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                AppIconView(size: 24)
                Text(ShellCopy.appName.text)
                    .font(.system(size: Tokens.FontSize.head, weight: .bold))
            }
            .padding(.horizontal, 6)

            VStack(spacing: 2) {
                ForEach(Self.tabs, id: \.place) { entry in
                    row(
                        entry.copy.text, symbol: entry.symbol, selected: context.navigator.place == entry.place,
                        badge: entry.place == .needsYou ? Self.badge(for: context.inbox.openCount) : nil
                    ) {
                        context.navigator.show(entry.place)
                    }
                }
            }

            projects

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
        .task(id: projectListAttempt) { await context.watchProjects() }
    }

    /// One tab of the pane.
    struct Tab: Equatable {
        let place: Navigator.Place
        let copy: ShellCopy
        let symbol: String
    }

    /// The tabs, top to bottom.
    static let tabs: [Tab] = [
        Tab(place: .board, copy: .tabBoard, symbol: "square.grid.3x1.below.line.grid.1x2"),
        Tab(place: .needsYou, copy: .tabNeedsYou, symbol: "bell"),
        Tab(place: .decided, copy: .tabDecided, symbol: "checkmark.circle"),
        Tab(place: .activity, copy: .tabActivity, symbol: "clock"),
        Tab(place: .agents, copy: .tabAgents, symbol: "person.2"),
        Tab(place: .credentials, copy: .tabCredentials, symbol: "key"),
        Tab(place: .handoff, copy: .tabHandoff, symbol: "arrow.triangle.swap"),
        Tab(place: .settings, copy: .tabSettings, symbol: "gearshape"),
    ]

    /// The count on the Needs you tab; nil when nothing is open.
    static func badge(for count: Int) -> String? { count > 0 ? String(count) : nil }

    private var projects: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(ShellCopy.projects.text)
                    .foregroundStyle(Tokens.Palette.text2)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button(ShellCopy.manageProjects.text) { context.navigator.show(.projects) }
                    .buttonStyle(.link)
                    .accessibilityLabel(ShellCopy.manageProjectsAccessibility.text)
            }
            .font(.system(size: Tokens.FontSize.small, weight: .semibold))
            .padding(.horizontal, 8)

            if let failure = context.projectListFailure {
                VStack(alignment: .leading, spacing: 4) {
                    Text(failure.text).foregroundStyle(Tokens.Tone.stop.foreground)
                    Button(ShellCopy.tryAgain.text) { projectListAttempt += 1 }.buttonStyle(.link)
                }
                .font(.system(size: Tokens.FontSize.small))
                .padding(.horizontal, 8)
            }

            ScrollView {
                LazyVStack(spacing: 2) {
                    projectRow(ShellCopy.allProjects.text, id: nil, symbol: "square.grid.2x2")
                    ForEach(Self.orderedProjects(context.paneProjects), id: \.id) { project in
                        projectRow(
                            project.name.isEmpty ? ProjectsCopy.deletedProject.text : project.name,
                            id: project.id, symbol: "folder",
                            tint: project.imaginarium ? Tokens.Palette.imaginariumTint : nil)
                    }
                }
            }
        }
    }

    /// The projects in the order the pane lists them: the Imaginarium project
    /// first, the rest in the order they came.
    static func orderedProjects(_ projects: [Project]) -> [Project] {
        projects.filter(\.imaginarium) + projects.filter { !$0.imaginarium }
    }

    private func projectRow(
        _ name: String, id: UUID?, symbol: String, tint: LinearGradient? = nil
    ) -> some View {
        row(name, symbol: symbol, selected: context.navigator.boardFilter.projectID == id, tint: tint) {
            context.navigator.selectProject(id)
        }
    }

    private func row(
        _ title: String, symbol: String, selected: Bool, badge: String? = nil, tint: LinearGradient? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .frame(width: 16)
                Text(verbatim: title)
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
                } else if let tint {
                    RoundedRectangle(cornerRadius: Tokens.Radius.control, style: .continuous)
                        .fill(tint)
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
