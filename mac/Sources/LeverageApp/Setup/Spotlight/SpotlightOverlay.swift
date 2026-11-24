import SwiftUI

/// Where the hole, the arrow and the note go, as the mockup's `drawGuide()` places them.
enum SpotlightLayout {
    static let holePadding: CGFloat = 6
    static let holeRadius: CGFloat = 12
    static let arrowSize: CGFloat = 28
    static let noteWidth: CGFloat = 292
    private static let margin: CGFloat = 12

    /// The hole: the control grown on each side.
    static func hole(around control: CGRect) -> CGRect {
        control.insetBy(dx: -holePadding, dy: -holePadding)
    }

    /// The top-left corners of the arrow and the note.
    static func place(
        hole: CGRect, side: SetupGuideNote.Side, note: CGSize, in bounds: CGSize
    ) -> (arrow: CGPoint, note: CGPoint) {
        func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat { max(low, min(high, value)) }
        let midX = hole.midX, midY = hole.midY
        let arrow: CGPoint
        var left: CGFloat
        let top: CGFloat
        switch side {
        case .right:
            arrow = CGPoint(x: hole.maxX + 8, y: midY - arrowSize / 2)
            left = hole.maxX + 44
            top = clamp(midY - 44, margin, bounds.height - note.height - margin)
        case .left:
            arrow = CGPoint(x: hole.minX - 36, y: midY - arrowSize / 2)
            left = hole.minX - 44 - note.width
            top = clamp(midY - 44, margin, bounds.height - note.height - margin)
        case .below:
            arrow = CGPoint(x: midX - arrowSize / 2, y: hole.maxY + 8)
            left = clamp(hole.maxX - note.width, margin, bounds.width - note.width - margin)
            top = hole.maxY + 44
        }
        left = clamp(left, margin, bounds.width - note.width - margin)
        return (arrow, CGPoint(x: left, y: top))
    }
}

/// The shade as drawn: the whole area with one rounded hole, filled even-odd.
struct SpotlightShade: Shape {
    let hole: CGRect

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        path.addRoundedRect(
            in: hole, cornerSize: CGSize(width: SpotlightLayout.holeRadius, height: SpotlightLayout.holeRadius),
            style: .continuous)
        return path
    }
}

/// Where the shade takes clicks: four bands round the hole. SwiftUI's
/// `Path.contains(_:eoFill:)` does not leave an even-odd hole out on macOS
/// 26, so hit testing is not left to the fill rule.
struct SpotlightShadeHitArea: Shape {
    let hole: CGRect

    func path(in rect: CGRect) -> Path {
        let hole = self.hole.intersection(rect)
        guard !hole.isNull else { return Path(rect) }
        var path = Path()
        path.addRect(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: hole.minY - rect.minY))
        path.addRect(CGRect(x: rect.minX, y: hole.maxY, width: rect.width, height: rect.maxY - hole.maxY))
        path.addRect(CGRect(x: rect.minX, y: hole.minY, width: hole.minX - rect.minX, height: hole.height))
        path.addRect(CGRect(x: hole.maxX, y: hole.minY, width: rect.maxX - hole.maxX, height: hole.height))
        return path
    }
}

/// The shell's spotlight: drawn once over the app from the controls' anchors.
/// It fades in when it first appears and stays steady as it moves between controls.
struct SpotlightLayer: View {
    let setup: SetupModel
    let navigator: Navigator
    let anchors: [SpotlightTarget: Anchor<CGRect>]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let note = SetupGuide.visibleNote(setup, navigator: navigator)
            let anchor = note.flatMap { anchors[$0.target] }
            ZStack {
                if let note, let anchor {
                    SpotlightOverlay(
                        note: note, target: proxy[anchor], size: proxy.size, notNow: { setup.notNow() },
                        finish: { setup.finishChecklist() }
                    )
                    .transition(.opacity)
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: anchor != nil)
        }
    }
}

/// The shade with its hole, the ring, the arrow and the note. Only the lit
/// control can be clicked: every click on the shade is swallowed.
struct SpotlightOverlay: View {
    let note: SetupGuideNote
    /// The lit control, in this view's coordinates.
    let target: CGRect
    let size: CGSize
    let notNow: () -> Void
    let finish: () -> Void
    @State private var noteSize = CGSize(width: SpotlightLayout.noteWidth, height: 150)

    var body: some View {
        let hole = SpotlightLayout.hole(around: target)
        let placed = SpotlightLayout.place(hole: hole, side: note.side, note: noteSize, in: size)
        ZStack(alignment: .topLeading) {
            SpotlightShade(hole: hole)
                .fill(Tokens.Spotlight.shade, style: FillStyle(eoFill: true))
                .contentShape(SpotlightShadeHitArea(hole: hole))
                .onTapGesture {}
                .accessibilityHidden(true)
            SpotlightRing()
                .frame(width: hole.width, height: hole.height)
                .offset(x: hole.minX, y: hole.minY)
            SpotlightArrow(side: note.side)
                .offset(x: placed.arrow.x, y: placed.arrow.y)
            SpotlightNoteView(note: note, notNow: notNow, finish: finish)
                .frame(width: SpotlightLayout.noteWidth)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGSize.self, of: { $0.size }, action: { noteSize = $0 })
                .offset(x: placed.note.x, y: placed.note.y)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }
}

/// The ring round the hole, with a pulse unless Reduce Motion is on.
private struct SpotlightRing: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: SpotlightLayout.holeRadius, style: .continuous)
        ZStack {
            // The glow stays outside the hole, so the lit control keeps its own colours.
            shape
                .stroke(Tokens.Spotlight.glow.opacity(0.45), lineWidth: 8)
                .shadow(color: Tokens.Spotlight.glow, radius: 15)
                .mask(OutsideHole().fill(style: FillStyle(eoFill: true)))
            shape
                .strokeBorder(Tokens.Spotlight.ring, lineWidth: 2)
            if !reduceMotion {
                RoundedRectangle(cornerRadius: pulsing ? 22 : 14, style: .continuous)
                    .strokeBorder(Tokens.Spotlight.ring, lineWidth: 2)
                    .padding(pulsing ? -16 : -2)
                    .opacity(pulsing ? 0 : 0.9)
                    .onAppear {
                        withAnimation(.easeOut(duration: 1.7).repeatForever(autoreverses: false)) { pulsing = true }
                    }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Everything round the hole, out to where the glow fades: the ring's glow is drawn only here.
private struct OutsideHole: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path(rect.insetBy(dx: -48, dy: -48))
        path.addRoundedRect(
            in: rect, cornerSize: CGSize(width: SpotlightLayout.holeRadius, height: SpotlightLayout.holeRadius),
            style: .continuous)
        return path
    }
}

/// The arrow beside the lit control, pointing at it, with a nudge unless
/// Reduce Motion is on.
private struct SpotlightArrow: View {
    let side: SetupGuideNote.Side
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var nudged = false

    var body: some View {
        Image(systemName: "arrow.left")
            .font(.system(size: 20, weight: .heavy))
            .foregroundStyle(Tokens.Spotlight.noteForeground)
            .offset(x: nudged ? -6 : 0)
            .frame(width: SpotlightLayout.arrowSize, height: SpotlightLayout.arrowSize)
            .rotationEffect(rotation)
            .shadow(color: .black.opacity(0.5), radius: 3, y: 2)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) { nudged = true }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var rotation: Angle {
        switch side {
        case .right: .degrees(0)
        case .below: .degrees(90)
        case .left: .degrees(180)
        }
    }
}

/// The blue note: the step, the title, the sentence and its buttons. Escape
/// is the same as Not now.
private struct SpotlightNoteView: View {
    let note: SetupGuideNote
    let notNow: () -> Void
    let finish: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: note.stepLine)
                    .font(.system(size: Tokens.FontSize.badge, weight: .semibold))
                    .opacity(0.82)
                Text(verbatim: note.title)
                    .font(.system(size: Tokens.FontSize.head, weight: .bold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: note.body)
                    .font(.system(size: Tokens.FontSize.body))
                    .lineSpacing(2)
                    .opacity(0.95)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityHidden(true)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                if note.offersFinish {
                    Button(SetupChecklistCopy.finishSetup.text, action: finish)
                        .buttonStyle(SpotlightNoteButtonStyle(isMain: true))
                    // Escape still puts the spotlight away.
                    Button(SetupChecklistCopy.notNow.text, action: notNow)
                        .keyboardShortcut(.cancelAction)
                        .frame(width: 0, height: 0)
                        .opacity(0)
                        .accessibilityHidden(true)
                } else {
                    Button(SetupChecklistCopy.notNow.text, action: notNow)
                        .buttonStyle(SpotlightNoteButtonStyle(isMain: false))
                        .keyboardShortcut(.cancelAction)
                }
            }
            .padding(.top, 4)
        }
        .foregroundStyle(Tokens.Spotlight.noteForeground)
        .padding(EdgeInsets(top: 14, leading: 16, bottom: 12, trailing: 16))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.Palette.primary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Tokens.Spotlight.noteForeground.opacity(0.25), lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 22, y: 18)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: note.accessibilityLabel))
        .accessibilityValue(Text(verbatim: note.stepLine))
    }
}

/// A button on the blue note: outlined, or white for the main one.
private struct SpotlightNoteButtonStyle: ButtonStyle {
    let isMain: Bool

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: Tokens.Radius.control, style: .continuous)
        configuration.label
            .font(.system(size: Tokens.FontSize.small, weight: .semibold))
            .padding(.horizontal, 10)
            .frame(minHeight: 28)
            .foregroundStyle(isMain ? Tokens.Spotlight.mainButtonText : Tokens.Spotlight.noteForeground)
            .background(shape.fill(isMain ? Tokens.Spotlight.noteForeground : Color.clear))
            .overlay(
                shape.strokeBorder(
                    isMain ? Tokens.Spotlight.noteForeground : Tokens.Spotlight.noteForeground.opacity(0.4),
                    lineWidth: 1))
            .opacity(configuration.isPressed ? 0.85 : 1)
            .contentShape(shape)
    }
}
