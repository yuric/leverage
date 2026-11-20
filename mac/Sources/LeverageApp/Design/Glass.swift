import SwiftUI

/// Glass for the window's two surfaces, which gives way to solid colour when
/// Reduce Transparency is on (the mockup's flat appearance).
struct GlassSurface: ViewModifier {
    enum Role: Sendable { case shell, nav }

    let role: Role
    let radius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background {
                if reduceTransparency {
                    shape.fill(role == .shell ? Tokens.Palette.flatShell : Tokens.Palette.flatNav)
                } else {
                    shape.fill(.ultraThinMaterial)
                        .overlay(shape.fill(role == .shell ? Tokens.Palette.shell : Tokens.Palette.nav))
                }
            }
            .overlay(shape.strokeBorder(reduceTransparency ? Tokens.Palette.flatRim : Tokens.Palette.rim, lineWidth: 1))
            .shadow(color: .black.opacity(role == .shell ? 0.12 : 0.08), radius: role == .shell ? 18 : 8, y: 4)
    }
}

/// The soft blue and lavender light behind the glass; plain when
/// Reduce Transparency is on.
struct Backdrop: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if reduceTransparency {
            Tokens.Palette.flatBackdrop
        } else {
            ZStack {
                Tokens.Palette.backdropBase
                RadialGradient(
                    colors: [Tokens.Palette.tintA, .clear], center: .topLeading, startRadius: 0, endRadius: 520)
                RadialGradient(
                    colors: [Tokens.Palette.tintB, .clear], center: .topTrailing, startRadius: 0, endRadius: 560)
            }
        }
    }
}

extension View {
    /// Draws this view on a glass surface.
    func glass(_ role: GlassSurface.Role, radius: CGFloat) -> some View {
        modifier(GlassSurface(role: role, radius: radius))
    }
}

/// A chip: a short state word on a toned background.
struct Chip: View {
    let text: String
    let tone: Tokens.Tone

    var body: some View {
        Text(text)
            .font(.system(size: Tokens.FontSize.small, weight: .semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .foregroundStyle(tone.foreground)
            .background(tone.background, in: RoundedRectangle(cornerRadius: Tokens.Radius.chip, style: .continuous))
    }
}

/// The app icon: a lever lifting a block, as in the mockup.
struct AppIconView: View {
    var size: CGFloat = 28

    var body: some View {
        Canvas { context, canvas in
            let unit = canvas.width / 64
            let blue = Color(nsColor: NSColor(hex: 0x0A63E0))
            context.fill(
                Path(roundedRect: CGRect(origin: .zero, size: canvas), cornerRadius: 14.4 * unit), with: .color(blue))
            var lever = Path()
            lever.move(to: CGPoint(x: 8 * unit, y: 30 * unit))
            lever.addLine(to: CGPoint(x: 56 * unit, y: 46 * unit))
            context.stroke(lever, with: .color(.white), style: StrokeStyle(lineWidth: 7 * unit, lineCap: .round))
            var fulcrum = Path()
            fulcrum.move(to: CGPoint(x: 21 * unit, y: 38 * unit))
            fulcrum.addLine(to: CGPoint(x: 29 * unit, y: 53 * unit))
            fulcrum.addLine(to: CGPoint(x: 13 * unit, y: 53 * unit))
            fulcrum.closeSubpath()
            context.fill(fulcrum, with: .color(.white))
            let block = Path(roundedRect: CGRect(x: 9 * unit, y: 13 * unit, width: 14 * unit, height: 12 * unit), cornerRadius: 2.5 * unit)
            let center = CGPoint(x: 16 * unit, y: 25 * unit)
            let tilt = CGAffineTransform(translationX: center.x, y: center.y)
                .rotated(by: 18.4 * .pi / 180)
                .translatedBy(x: -center.x, y: -center.y)
            context.fill(block.applying(tilt), with: .color(.white))
            var arrow = Path()
            arrow.move(to: CGPoint(x: 44 * unit, y: 24 * unit))
            arrow.addLine(to: CGPoint(x: 49.5 * unit, y: 30 * unit))
            arrow.addLine(to: CGPoint(x: 55 * unit, y: 24 * unit))
            context.stroke(arrow, with: .color(.white), style: StrokeStyle(lineWidth: 4 * unit, lineCap: .round, lineJoin: .round))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
