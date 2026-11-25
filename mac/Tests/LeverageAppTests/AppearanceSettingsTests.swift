import Foundation
import SwiftUI
import Testing

@testable import LeverageApp

@MainActor
@Suite("Appearance settings")
struct AppearanceSettingsTests {
    @Test("the system option is the default and clearing an override follows the Mac")
    func appearanceChoices() throws {
        let name = "leverage-appearance-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }

        let windowPreference = AppStorage(
            wrappedValue: AppAppearance.system, AppAppearance.preferenceKey, store: defaults)
        #expect(windowPreference.wrappedValue == .system)
        #expect(windowPreference.wrappedValue.colorScheme == nil)
        #expect(AppAppearance.allCases.map { $0.label.text } == ["Same as this Mac", "Light", "Dark"])

        windowPreference.wrappedValue = .dark
        let reopenedPreference = AppStorage(
            wrappedValue: AppAppearance.system, AppAppearance.preferenceKey, store: defaults)
        #expect(reopenedPreference.wrappedValue == .dark)
        #expect(reopenedPreference.wrappedValue.colorScheme == .dark)

        reopenedPreference.wrappedValue = .light
        #expect(reopenedPreference.wrappedValue.colorScheme == .light)
        #expect(defaults.string(forKey: AppAppearance.preferenceKey) == AppAppearance.light.rawValue)

        reopenedPreference.wrappedValue = .system
        #expect(reopenedPreference.wrappedValue.colorScheme == nil)
        #expect(defaults.string(forKey: AppAppearance.preferenceKey) == AppAppearance.system.rawValue)
    }

    @Test("the Settings panel draws with each appearance selected", arguments: AppAppearance.allCases)
    func render(appearance: AppAppearance) {
        let settings = AppearanceSettingsView(selection: .constant(appearance))
            .preferredColorScheme(appearance.colorScheme)
        #expect(AgentFixtures.draws(settings, width: 460, height: 180))
    }
}
