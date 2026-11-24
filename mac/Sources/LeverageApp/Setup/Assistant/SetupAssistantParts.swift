import SwiftUI

// The pieces every screen of the setup assistant is built from.

/// One screen: its content, laid out plainly when it fits and scrolling
/// when the window is too short for it, and the row of buttons under a
/// line at the bottom. Welcome is centered in the height it has.
struct AssistantScreen<Content: View, Footer: View>: View {
    var centered = false
    @ViewBuilder let content: Content
    @ViewBuilder let footer: Footer

    var body: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .vertical) {
                stack
                    .frame(maxHeight: .infinity, alignment: centered ? .center : .top)
                ScrollView { stack }
                    .scrollBounceBehavior(.basedOnSize)
            }
            .frame(maxHeight: .infinity, alignment: .top)
            VStack(spacing: 0) {
                Rectangle().fill(Tokens.Palette.line).frame(height: 1)
                HStack(spacing: 8) { footer }
                    .padding(.top, 14)
            }
            .padding(.top, 20)
        }
    }

    private var stack: some View {
        VStack(alignment: centered ? .center : .leading, spacing: centered ? 22 : 16) {
            content
        }
        .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
        .padding(.horizontal, 4)
        .padding(.bottom, 12)
    }
}

/// A screen's title and the sentence under it.
struct AssistantHeading: View {
    let title: String
    let body_: String
    var centered = false

    init(_ title: SetupAssistantCopy, _ body: SetupAssistantCopy, centered: Bool = false) {
        self.title = title.text
        self.body_ = body.text
        self.centered = centered
    }

    var body: some View {
        VStack(alignment: centered ? .center : .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 20, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            Text(body_)
                .font(.system(size: 14))
                .foregroundStyle(Tokens.Palette.text2)
                .frame(maxWidth: 460, alignment: centered ? .center : .leading)
        }
        .multilineTextAlignment(centered ? .center : .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// A steady surface: the cards, lists and forms of the assistant.
struct AssistantCard: ViewModifier {
    var padding: CGFloat = 0

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
        content
            .padding(padding)
            .background(Tokens.Palette.surface, in: shape)
            .overlay(shape.strokeBorder(Tokens.Palette.line, lineWidth: 1))
            .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
    }
}

extension View {
    func assistantCard(padding: CGFloat = 0) -> some View { modifier(AssistantCard(padding: padding)) }
}

/// Rows on one card, with a line between each.
struct AssistantList<Item: Identifiable, Row: View>: View {
    let items: [Item]
    let label: String
    @ViewBuilder let row: (Item) -> Row

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 { Rectangle().fill(Tokens.Palette.line).frame(height: 1) }
                row(item)
            }
        }
        .assistantCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(label))
    }
}

/// A note on the inset colour, or on the wait tone where something will wait.
struct AssistantNote<Extra: View>: View {
    let text: String
    var wait = false
    @ViewBuilder var extra: Extra

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
            extra
        }
        .font(.system(size: Tokens.FontSize.small))
        .foregroundStyle(wait ? Tokens.Tone.wait.foreground : Tokens.Palette.text)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            wait ? Tokens.Tone.wait.background : Tokens.Palette.inset,
            in: RoundedRectangle(cornerRadius: Tokens.Radius.control, style: .continuous))
    }
}

extension AssistantNote where Extra == EmptyView {
    init(text: String, wait: Bool = false) {
        self.init(text: text, wait: wait) { EmptyView() }
    }
}

/// A line in the stop tone for something that did not work.
struct AssistantProblem: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: Tokens.FontSize.body, weight: .medium))
            .foregroundStyle(Tokens.Tone.stop.foreground)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Small grey text.
struct AssistantMuted: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: Tokens.FontSize.small))
            .foregroundStyle(Tokens.Palette.text2)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A plain bordered button: Back, Cancel, Continue with one.
struct AssistantButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: Tokens.Radius.control, style: .continuous)
        configuration.label
            .font(.system(size: Tokens.FontSize.body, weight: .medium))
            .padding(.horizontal, 12)
            .frame(minHeight: 36)
            .foregroundStyle(Tokens.Palette.text)
            .background(Tokens.Palette.control, in: shape)
            .overlay(shape.strokeBorder(Tokens.Palette.line, lineWidth: 1))
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.38)
            .contentShape(shape)
    }
}

/// The tinted button that starts a step inside a screen: Sign in, Retry, Install.
struct AssistantTintStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: Tokens.Radius.control, style: .continuous)
        configuration.label
            .font(.system(size: Tokens.FontSize.body, weight: .semibold))
            .padding(.horizontal, 12)
            .frame(minHeight: 36)
            .foregroundStyle(Tokens.Tone.info.foreground)
            .background(Tokens.Tone.info.background, in: shape)
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.38)
            .contentShape(shape)
    }
}

/// A quiet text button: "Set up later" in the link colour, and the grey
/// ones under a screen's content.
struct AssistantLinkStyle: ButtonStyle {
    var quiet = false
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: Tokens.FontSize.body, weight: quiet ? .medium : .semibold))
            .foregroundStyle(
                quiet ? Tokens.Palette.text2 : (colorScheme == .dark ? Tokens.Palette.focus : Tokens.Palette.primary))
            .underline(configuration.isPressed)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .frame(minHeight: 28)
            .contentShape(Rectangle())
    }
}

/// The footer's Back button.
struct AssistantBackButton: View {
    let model: SetupAssistantModel

    var body: some View {
        Button(CredentialsCopy.back.text) { model.back() }
            .buttonStyle(AssistantButtonStyle())
    }
}

/// The one raised blue button of a screen.
struct AssistantPrimaryButton: View {
    let title: String
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .buttonStyle(PrimaryButtonStyle())
            .keyboardShortcut(.defaultAction)
            .disabled(!enabled)
    }
}
