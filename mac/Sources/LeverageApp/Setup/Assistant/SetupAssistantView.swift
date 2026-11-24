import SwiftUI

/// The setup assistant: the full-window sequence a new installation opens
/// on (docs/onboarding/PRD.md). Built with no arguments; the shell puts its
/// `ScreenContext` in the environment.
struct SetupAssistantView: View {
    @Environment(ScreenContext.self) private var context

    var body: some View {
        Text(SetupAssistantCopy.welcomeTitle.text)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
