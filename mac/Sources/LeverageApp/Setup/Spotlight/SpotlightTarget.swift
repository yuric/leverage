import SwiftUI

/// The controls the setup spotlight can light.
enum SpotlightTarget: Hashable, Sendable {
    case credentialsTab
    case addCredential
    case agentsTab
    case connectAgent
    case addTask
    /// The card of the first finished task, on the task board.
    case doneTask
}

/// Where each control that can be lit is, gathered up the view tree for the
/// spotlight, which the shell draws once over the app.
struct SpotlightAnchorKey: PreferenceKey {
    static var defaultValue: [SpotlightTarget: Anchor<CGRect>] { [:] }

    static func reduce(value: inout [SpotlightTarget: Anchor<CGRect>], nextValue: () -> [SpotlightTarget: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

extension View {
    /// Tells the spotlight where this control is, so it can be lit. A nil
    /// target publishes nothing.
    func spotlightAnchor(_ target: SpotlightTarget?) -> some View {
        anchorPreference(key: SpotlightAnchorKey.self, value: .bounds) { anchor in
            target.map { [$0: anchor] } ?? [:]
        }
    }

    /// Tells setup whether this screen has a sheet open, so the spotlight
    /// steps aside until it closes. Outside the shell's environment it does nothing.
    func setupSheetOpen(_ isOpen: Bool) -> some View {
        modifier(SetupSheetReporter(isOpen: isOpen))
    }
}

/// Sets `SetupModel.isSheetOpen` as a screen's sheet opens and closes.
private struct SetupSheetReporter: ViewModifier {
    let isOpen: Bool
    @Environment(ScreenContext.self) private var context: ScreenContext?

    func body(content: Content) -> some View {
        content
            .onChange(of: isOpen) { _, open in
                context?.setup.isSheetOpen = open
            }
            .onDisappear {
                if isOpen { context?.setup.isSheetOpen = false }
            }
    }
}
