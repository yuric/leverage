import LeverageKit
import SwiftUI

@main
struct LeverageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @AppStorage(AppAppearance.preferenceKey) private var appearance = AppAppearance.system
    @State private var model = AppModel(
        runtime: Live.runtime(),
        makeOwnerAPI: { url, token in OwnerClient(baseURL: url, sessionToken: token) })

    var body: some Scene {
        Window(ShellCopy.appName.text, id: Self.windowID) {
            WindowRoot(model: model, delegate: delegate)
                .preferredColorScheme(appearance.colorScheme)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1040, height: 700)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(ShellCopy.addTask.text) { model.screens?.navigator.presentAddTask() }
                    .keyboardShortcut("n")
                    .disabled(!model.isSignedIn)
            }
            CommandGroup(before: .appTermination) {
                Button(ShellCopy.signOut.text) { Task { await model.signOut() } }
                    .disabled(!model.isSignedIn)
                Divider()
            }
        }

        Settings {
            AppearanceSettingsView(selection: $appearance)
                .preferredColorScheme(appearance.colorScheme)
        }
    }

    static let windowID = "main"
}

/// The window's content, and the two things only the window can tell the
/// delegate: how to open the window again, and what to finish before quitting.
private struct WindowRoot: View {
    let model: AppModel
    let delegate: AppDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        RootView(model: model)
            .task { await model.launch() }
            .onAppear {
                delegate.openMainWindow = { openWindow(id: LeverageApp.windowID) }
                delegate.terminationWork = { await model.prepareToQuit() }
            }
    }
}
