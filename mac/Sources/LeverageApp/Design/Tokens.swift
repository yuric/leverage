import AppKit
import SwiftUI

/// The mockup's design tokens (`docs/design/mockup.html`, section 1): colours,
/// corners and type sizes. The mockup's HTML and class names do not carry
/// over; these numbers and colours do. Colours follow the system appearance.
enum Tokens {
    /// The window may not be narrower than this (MA-22): the narrow rail is not built.
    static let minimumWindowWidth: CGFloat = 860
    static let minimumWindowHeight: CGFloat = 560
    static let sidePaneWidth: CGFloat = 188

    enum Radius {
        static let window: CGFloat = 18
        static let nav: CGFloat = 14
        static let card: CGFloat = 12
        static let tab: CGFloat = 10
        static let control: CGFloat = 8
        static let chip: CGFloat = 6
    }

    enum FontSize {
        static let head: CGFloat = 15
        static let body: CGFloat = 13
        static let small: CGFloat = 12
        static let badge: CGFloat = 11
    }

    enum Spacing {
        static let window: CGFloat = 6
        static let sheet: CGFloat = 20
    }

    /// Colours as light and dark pairs; `alpha` is the mockup's rgba alpha.
    enum Palette {
        static let backdropBase = pair(0xE8EDFA, 0x0D111E)
        static let tintA = pair(0x76A0FF, 0x3E68EB, lightAlpha: 0.6, darkAlpha: 0.55)
        static let tintB = pair(0xB496FF, 0x885CE0, lightAlpha: 0.55, darkAlpha: 0.5)
        static let shell = pair(0xFFFFFF, 0x1E2234, lightAlpha: 0.5, darkAlpha: 0.56)
        static let nav = pair(0xFFFFFF, 0x2C3148, lightAlpha: 0.34, darkAlpha: 0.6)
        static let rim = pair(0xFFFFFF, 0xFFFFFF, lightAlpha: 0.8, darkAlpha: 0.16)
        static let surface = pair(0xFFFFFF, 0x1B1E2D, lightAlpha: 0.95, darkAlpha: 0.95)
        static let sheet = pair(0xFFFFFF, 0x1D2032)
        static let inset = pair(0xEEF2FC, 0x262A3F)
        static let control = pair(0xF3F5FB, 0x262A3F)
        static let line = pair(0xD5DAE8, 0x3A405A)
        static let field = pair(0x7A8298, 0x6B7391)
        static let text = pair(0x1A1E29, 0xF2F4FA)
        static let text2 = pair(0x444C60, 0xBAC1D6)
        static let ok = pair(0x1C8A52, 0x57D08F)
        static let placeholder = pair(0x6B7280, 0x9AA3BC)
        static let primary = pair(0x0A63E0, 0x1F6FEB)
        static let primaryForeground = pair(0xFFFFFF, 0xFFFFFF)
        static let focus = pair(0x0A63E0, 0x8AB4FF)
        static let tabForeground = pair(0x2F3648, 0xD5DAEA)
        static let tabOnBackground = pair(0xFFFFFF, 0x3A4160)
        static let tabOnForeground = pair(0x11141D, 0xFFFFFF)
        static let scrim = pair(0x181E3A, 0x05070E, lightAlpha: 0.3, darkAlpha: 0.55)

        /// The very faint rainbow behind the Imaginarium project's row in the side pane.
        static let imaginariumTint = LinearGradient(
            colors: [
                Color(red: 1, green: 0.435, blue: 0.71).opacity(0.10),
                Color(red: 1, green: 0.894, blue: 0.361).opacity(0.07),
                Color(red: 0.424, green: 0.784, blue: 0.996).opacity(0.10),
            ],
            startPoint: .leading, endPoint: .trailing)

        // The same surfaces when Reduce Transparency is on: solid, no blur.
        static let flatBackdrop = pair(0xE4E9F6, 0x0D111E)
        static let flatShell = pair(0xF4F6FC, 0x171A28)
        static let flatNav = pair(0xE3E8F4, 0x242838)
        static let flatRim = pair(0xB9C1D6, 0x4A5170)
        static let flatSurface = pair(0xFFFFFF, 0x1B1E2D)
    }

    /// The five tones that signal state, and only state (the mockup's chips).
    enum Tone: Sendable {
        case wait, done, info, stop, plain

        var background: Color {
            switch self {
            case .wait: pair(0xFFEFCF, 0x4B3611)
            case .done: pair(0xDDF5E6, 0x12402A)
            case .info: pair(0xE2EDFF, 0x17336A)
            case .stop: pair(0xFFE4D3, 0x4D2613)
            case .plain: pair(0xEEF2FC, 0x262A3F)
            }
        }

        var foreground: Color {
            switch self {
            case .wait: pair(0x7A4300, 0xFFD899)
            case .done: pair(0x0B6237, 0xA6ECC4)
            case .info: pair(0x0B4AA8, 0xC2DAFF)
            case .stop: pair(0x8A3A0B, 0xFFCBAA)
            case .plain: pair(0x1A1E29, 0xF2F4FA)
            }
        }
    }

    private static func pair(_ light: UInt32, _ dark: UInt32) -> Color { Palette.pair(light, dark) }
}

extension Tokens.Palette {
    /// A colour that is `light` in the light appearance and `dark` in the dark one.
    static func pair(
        _ light: UInt32, _ dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1
    ) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark ? NSColor(hex: dark, alpha: darkAlpha) : NSColor(hex: light, alpha: lightAlpha)
        })
    }
}

extension NSColor {
    /// An sRGB colour from `0xRRGGBB`.
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}
