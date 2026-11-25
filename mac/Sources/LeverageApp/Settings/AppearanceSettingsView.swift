import AppKit
import SwiftUI

enum AppAppearance: String, CaseIterable {
    static let preferenceKey = "appAppearance"

    case system
    case light
    case dark

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    /// The same choice for AppKit: nil follows the Mac.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    /// Sets the choice for the whole app. `preferredColorScheme` reaches only
    /// the SwiftUI windows; a panel AppKit opens on its own, such as Choose
    /// folder, follows the app's appearance.
    @MainActor
    func apply(to application: NSApplication = .shared) {
        application.appearance = nsAppearance
    }

    var label: AppearanceSettingsCopy {
        switch self {
        case .system: .system
        case .light: .light
        case .dark: .dark
        }
    }
}

enum AppearanceSettingsCopy: OwnerFacingCopy {
    case heading, system, light, dark

    var text: String {
        switch self {
        case .heading: "Appearance"
        case .system: "Same as this Mac"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

struct AppearanceSettingsView: View {
    @Binding var selection: AppAppearance

    var body: some View {
        Form {
            Section(AppearanceSettingsCopy.heading.text) {
                HStack(spacing: 12) {
                    ForEach(AppAppearance.allCases, id: \.self) { appearance in
                        choice(appearance)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func choice(_ appearance: AppAppearance) -> some View {
        let selected = selection == appearance
        return Button {
            selection = appearance
        } label: {
            VStack(spacing: 7) {
                AppearancePreview(scheme: appearance.colorScheme)
                    .accessibilityHidden(true)

                HStack(spacing: 5) {
                    Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                        .accessibilityHidden(true)
                    Text(appearance.label.text)
                }
                .font(.callout)
            }
            .frame(maxWidth: .infinity)
            .padding(6)
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        selected ? Color.accentColor : Color.secondary.opacity(0.3),
                        lineWidth: selected ? 2 : 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(appearance.label.text)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct AppearancePreview: View {
    let scheme: ColorScheme?

    var body: some View {
        GeometryReader { geometry in
            if let scheme {
                window(scheme)
            } else {
                window(.light)
                    .overlay {
                        window(.dark)
                            .mask(alignment: .trailing) {
                                Rectangle().frame(width: geometry.size.width / 2)
                            }
                    }
            }
        }
        .frame(height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private func window(_ scheme: ColorScheme) -> some View {
        let isDark = scheme == .dark
        let panel = isDark ? Color.white.opacity(0.13) : Color.white
        let detail = isDark ? Color.white.opacity(0.25) : Color.black.opacity(0.11)

        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 2) {
                ForEach(0..<3) { _ in Circle().fill(detail).frame(width: 3, height: 3) }
            }
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(panel)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 4) {
                    RoundedRectangle(cornerRadius: 2).fill(detail).frame(width: 28, height: 4)
                    HStack(spacing: 3) {
                        RoundedRectangle(cornerRadius: 3).fill(panel)
                        RoundedRectangle(cornerRadius: 3).fill(panel)
                    }
                }
            }
        }
        .padding(5)
        .background(isDark ? Color(red: 0.07, green: 0.09, blue: 0.15) : Color(red: 0.86, green: 0.89, blue: 0.96))
    }
}
