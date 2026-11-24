import SwiftUI

/// One card of a lane: the title, one line of status, an optional chip and an
/// optional note box (the mockup's card). A click opens the task's page.
struct TaskCard: View {
    let card: BoardCard
    let open: (UUID) -> Void
    /// Setup lights the card of the first finished task; absent outside the shell.
    @Environment(ScreenContext.self) private var context: ScreenContext?

    var body: some View {
        Button {
            open(card.id)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: card.title)
                    .font(.system(size: Tokens.FontSize.body, weight: .semibold))
                    .foregroundStyle(Tokens.Palette.text)
                    .multilineTextAlignment(.leading)
                Text(verbatim: card.statusLine)
                    .font(.system(size: Tokens.FontSize.small))
                    .foregroundStyle(Tokens.Palette.text2)
                    .multilineTextAlignment(.leading)
                if let chip = card.chip {
                    Chip(text: chip.text, tone: chip.tone)
                }
                if let note = card.note {
                    Text(verbatim: note)
                        .font(.system(size: Tokens.FontSize.small))
                        .foregroundStyle(Tokens.Palette.text2)
                        .multilineTextAlignment(.leading)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            Tokens.Palette.inset,
                            in: RoundedRectangle(cornerRadius: Tokens.Radius.control, style: .continuous))
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Tokens.Palette.surface, in: RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                    .strokeBorder(Tokens.Palette.line, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .spotlightAnchor(
            context?.setup.presentation == .checklist && context?.setup.facts.doneTask?.id == card.id ? .doneTask : nil)
    }
}
