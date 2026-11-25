import SwiftUI

/// The window's whole content: the start-up screens, the sign-in screen, or
/// the app itself, by the model's phase.
struct RootView: View {
    let model: AppModel
    var settingsAreOpen = false

    var body: some View {
        ZStack {
            Backdrop().ignoresSafeArea()
            switch model.phase {
            case .starting, .dockerMissing, .dockerStarting, .dockerNotStarting, .imageMissing, .serverFailed,
                .servicesUnavailable, .databasePasswordsMissing, .cannotReachServer:
                StartupView(model: model)
            case .createSignIn, .signIn:
                if let signIn = model.signIn {
                    SignInView(model: signIn)
                }
            case .ready:
                if let context = model.screens {
                    AppShell(context: context, settingsAreOpen: settingsAreOpen, signOut: model.signOut)
                }
            }
        }
        .frame(minWidth: Tokens.minimumWindowWidth, minHeight: Tokens.minimumWindowHeight)
        .foregroundStyle(Tokens.Palette.text)
    }
}

/// The signed-in window. On a new installation it is the setup assistant,
/// with no side pane (docs/onboarding/PRD.md). Otherwise it is the app: the
/// floating side pane, the toolbar, and the screen the owner is on, with
/// the Add task sheet over it, and the setup spotlight while the checklist shows.
struct AppShell: View {
    let context: ScreenContext
    let settingsAreOpen: Bool
    let signOut: @MainActor () async -> Void

    var body: some View {
        Group {
            switch context.setup.presentation {
            case .undecided:
                // Nothing until the first read says which it is, so the app
                // never shows for a moment before the assistant.
                Color.clear
            case .assistant:
                SetupAssistantView()
            case .checklist, .none:
                app
            }
        }
        .environment(context)
        .task { await context.watchSetup() }
        .task { await context.startInbox() }
    }

    private var app: some View {
        @Bindable var navigator = context.navigator
        return HStack(alignment: .top, spacing: Tokens.Spacing.window) {
            SidePane(context: context, settingsAreOpen: settingsAreOpen, signOut: signOut)
            VStack(spacing: 0) {
                Toolbar(context: context)
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.leading, 16)
                    .padding(.trailing, 10)
                    .padding(.bottom, 20)
            }
        }
        .padding(Tokens.Spacing.window)
        .overlayPreferenceValue(SpotlightAnchorKey.self) { anchors in
            SpotlightLayer(setup: context.setup, navigator: context.navigator, anchors: anchors)
        }
        .setupSheetOpen(navigator.isAddTaskPresented)
        .sheet(isPresented: $navigator.isAddTaskPresented) {
            AddTaskSheet().environment(context)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch context.navigator.place {
        case .board:
            if context.navigator.openTaskID != nil {
                TaskPageView()
            } else {
                BoardView()
            }
        case .needsYou: NeedsYouView()
        case .decided: DecidedView()
        case .activity: ActivityView()
        case .agents: RosterView()
        case .credentials: CredentialsView()
        case .handoff: HandoffView()
        case .imaginarium: ImaginariumView()
        case .rules:
            TabView {
                RulesView().tabItem { Text(RulesCopy.title.text) }
                WorkspaceSettingsView().tabItem { Text(WorkspaceSettingsCopy.title.text) }
            }
        case .projects: ProjectsView()
        }
    }
}
