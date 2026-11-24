import SwiftUI

/// Welcome: what Leverage does, in one sentence and three small pictures
/// drawn with the tokens, and how long setup takes.
struct SetupWelcomeScreen: View {
    let model: SetupAssistantModel

    var body: some View {
        AssistantScreen(centered: true) {
            VStack(spacing: 6) {
                AppIconView(size: 56)
                    .padding(.bottom, 8)
                AssistantHeading(.welcomeTitle, .welcomeBody, centered: true)
            }
            HStack(alignment: .top, spacing: 10) {
                SnapshotCard(title: .snapAddTitle, body: .snapAddBody) { MiniBoardArt() }
                SnapshotCard(title: .snapPairTitle, body: .snapPairBody) { PairArt() }
                SnapshotCard(title: .snapAskTitle, body: .snapAskBody) { NeedsYouArt() }
            }
            .fixedSize(horizontal: false, vertical: true)
            AssistantMuted(text: SetupAssistantCopy.welcomeFoot.text)
                .multilineTextAlignment(.center)
        } footer: {
            Spacer(minLength: 0)
            AssistantPrimaryButton(title: SetupAssistantCopy.getStarted.text) { model.next() }
        }
    }
}

/// One of the three cards: a small picture, a title and a line.
private struct SnapshotCard<Art: View>: View {
    let title: SetupAssistantCopy
    let body_: SetupAssistantCopy
    @ViewBuilder let art: Art

    init(title: SetupAssistantCopy, body: SetupAssistantCopy, @ViewBuilder art: () -> Art) {
        self.title = title
        self.body_ = body
        self.art = art()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            art
                .frame(maxWidth: .infinity)
                .frame(height: 96)
                .background(
                    Tokens.Palette.inset, in: RoundedRectangle(cornerRadius: Tokens.Radius.control, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.control, style: .continuous))
                .accessibilityHidden(true)
            Text(title.text)
                .font(.system(size: Tokens.FontSize.body, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            AssistantMuted(text: body_.text)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .assistantCard(padding: 10)
        .accessibilityElement(children: .combine)
    }
}

/// A board of three lanes with one card in the middle one.
private struct MiniBoardArt: View {
    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            lane { slot }
            lane { card }
            lane { slot }
        }
        .frame(width: 156, height: 70, alignment: .top)
    }

    private func lane<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            GeometryReader { proxy in
                Capsule().fill(Tokens.Palette.field.opacity(0.6)).frame(width: proxy.size.width * 0.62, height: 4)
            }
            .frame(height: 4)
            content()
        }
        .frame(maxWidth: .infinity)
    }

    private var slot: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .strokeBorder(Tokens.Palette.field.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            .frame(height: 22)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 4) {
            MiniLine(fraction: 1)
            MiniLine(fraction: 0.58)
            RoundedRectangle(cornerRadius: 3).fill(Tokens.Palette.primary).frame(width: 22, height: 7)
                .padding(.top, 1)
        }
        .padding(6)
        .background(Tokens.Palette.surface, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Tokens.Palette.line, lineWidth: 1))
    }
}

/// A short bar standing for a line of text.
private struct MiniLine: View {
    let fraction: CGFloat

    var body: some View {
        GeometryReader { proxy in
            Capsule().fill(Tokens.Palette.text2.opacity(0.75)).frame(width: proxy.size.width * fraction, height: 3)
        }
        .frame(height: 3)
    }
}

/// One agent builds, an arrow, another reviews.
private struct PairArt: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            badge(fill: Tokens.Palette.primary, label: .snapBuilds) {
                BracketsShape()
                    .stroke(Tokens.Palette.primaryForeground, style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
                    .frame(width: 18, height: 11)
            }
            ArrowShape()
                .stroke(Tokens.Palette.field, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .frame(width: 34, height: 12)
                .padding(.top, 10)
            badge(fill: Tokens.Palette.ok, label: .snapReviews) {
                TickShape()
                    .stroke(Tokens.Palette.sheet, style: StrokeStyle(lineWidth: 2.6, lineCap: .round, lineJoin: .round))
                    .frame(width: 14, height: 12)
            }
        }
    }

    private func badge<Mark: View>(fill: Color, label: SetupAssistantCopy, @ViewBuilder mark: () -> Mark) -> some View {
        VStack(spacing: 8) {
            ZStack {
                Circle().fill(fill)
                mark()
            }
            .frame(width: 32, height: 32)
            Text(label.text)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Tokens.Palette.text2)
        }
    }
}

/// `< >`, for code being built.
private struct BracketsShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.3, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.3, y: rect.maxY))
        path.move(to: CGPoint(x: rect.maxX - rect.width * 0.3, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.3, y: rect.maxY))
        return path
    }
}

/// A line with an arrow head on the right.
private struct ArrowShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.move(to: CGPoint(x: rect.maxX - rect.height / 2, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX - rect.height / 2, y: rect.maxY))
        return path
    }
}

/// One waiting item, with the count Needs you shows.
private struct NeedsYouArt: View {
    var body: some View {
        HStack(spacing: 8) {
            TrayShape()
                .stroke(Tokens.Palette.text2, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                .frame(width: 14, height: 12)
            VStack(spacing: 4) {
                MiniLine(fraction: 1)
                MiniLine(fraction: 0.58)
            }
            Text(verbatim: "1")
                .font(.system(size: Tokens.FontSize.badge, weight: .bold))
                .foregroundStyle(Tokens.Tone.wait.foreground)
                .frame(minWidth: 18, minHeight: 18)
                .background(Tokens.Tone.wait.background, in: Capsule())
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(width: 156)
        .background(Tokens.Palette.surface, in: RoundedRectangle(cornerRadius: Tokens.Radius.control, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.Radius.control, style: .continuous)
                .strokeBorder(Tokens.Palette.line, lineWidth: 1))
    }
}

/// An inbox tray.
private struct TrayShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + h * 0.6))
        path.addLine(to: CGPoint(x: rect.minX + w * 0.18, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - w * 0.18, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + h * 0.6))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + h * 0.6))
        path.addLine(to: CGPoint(x: rect.minX + w * 0.3, y: rect.minY + h * 0.6))
        path.addLine(to: CGPoint(x: rect.minX + w * 0.38, y: rect.minY + h * 0.78))
        path.addLine(to: CGPoint(x: rect.maxX - w * 0.38, y: rect.minY + h * 0.78))
        path.addLine(to: CGPoint(x: rect.maxX - w * 0.3, y: rect.minY + h * 0.6))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + h * 0.6))
        return path
    }
}
