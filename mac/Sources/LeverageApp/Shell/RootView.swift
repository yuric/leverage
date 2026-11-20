import SwiftUI

/// The window's whole content: the start-up screens, the sign-in screen, or
/// the app itself, by the model's phase.
struct RootView: View {
    let model: AppModel

    var body: some View {
        ZStack {
            Backdrop().ignoresSafeArea()
            switch model.phase {
            case .starting, .dockerMissing, .dockerStarting, .dockerNotStarting, .imageMissing, .serverFailed,
                .cannotReachServer:
                StartupView(model: model)
            case .createSignIn, .signIn:
                if let signIn = model.signIn {
                    SignInView(model: signIn)
                }
            case .ready:
                if let context = model.screens {
                    AppShell(context: context)
                }
            }
        }
        .frame(minWidth: Tokens.minimumWindowWidth, minHeight: Tokens.minimumWindowHeight)
        .foregroundStyle(Tokens.Palette.text)
    }
}

/// The signed-in window: the floating side pane, the toolbar, and the screen
/// the owner is on, with the Add task sheet over it.
struct AppShell: View {
    let context: ScreenContext

    var body: some View {
        @Bindable var navigator = context.navigator
        HStack(alignment: .top, spacing: Tokens.Spacing.window) {
            SidePane(context: context)
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
        .environment(context)
        .task { await context.startInbox() }
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
        case .agents: RosterView()
        case .credentials: CredentialsView()
        case .handoff: HandoffView()
        case .settings: RulesView()
        }
    }
}
