import SwiftUI

/// The Handoff tab (HM-32 to HM-37): the one order of accounts, each naming
/// the account it hands off to, and the PRD's eight rules as sentences. It has
/// no switch and no way to reorder. Built with no arguments; the shell puts
/// its `ScreenContext` in the environment.
struct HandoffView: View {
    @Environment(ScreenContext.self) private var context
    @State private var box = ScreenModelBox<HandoffModel>()

    var body: some View {
        let model = box.model {
            HandoffModel(api: context.owner, noteRead: { [feed = context.feed] in feed.noteRead(asOfSeq: $0) })
        }
        HandoffContent(model: model)
            .task {
                model.attach(to: context.feed)
                await model.load()
            }
            .onDisappear { model.detach() }
    }
}

/// What the tab draws from its model.
struct HandoffContent: View {
    let model: HandoffModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            heading(HandoffCopy.title.text, hint: HandoffCopy.hint.text)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    order
                    rules
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: the order

    private var order: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch model.state {
            case .loading:
                note(HandoffCopy.loading.text)
            case .signedOut:
                note(ShellCopy.transportUnauthenticated.text, tone: Tokens.Tone.stop.foreground)
            case .failed(let copy):
                note(copy.text, tone: Tokens.Tone.stop.foreground)
            case .loaded:
                EmptyView()
            }
            if model.state == .loaded, model.rows.isEmpty {
                note(HandoffCopy.empty.text)
            }
            ForEach(model.rows) { row in
                HandoffRowView(row: row)
            }
        }
    }

    // MARK: the rules

    private var rules: some View {
        VStack(alignment: .leading, spacing: 8) {
            heading(HandoffCopy.rulesTitle.text, hint: HandoffCopy.rulesHint.text)
            ForEach(Array(HandoffCopy.rules.enumerated()), id: \.offset) { index, rule in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(verbatim: "\(index + 1).")
                        .font(.system(size: Tokens.FontSize.body, weight: .semibold))
                        .foregroundStyle(Tokens.Palette.text2)
                        .frame(width: 22, alignment: .trailing)
                    Text(verbatim: rule.text)
                        .font(.system(size: Tokens.FontSize.body))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func heading(_ title: String, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: title)
                .font(.system(size: 17, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            Text(verbatim: hint)
                .font(.system(size: Tokens.FontSize.body))
                .foregroundStyle(Tokens.Palette.text2)
        }
    }

    private func note(_ text: String, tone: Color = Tokens.Palette.text2) -> some View {
        Text(verbatim: text)
            .font(.system(size: Tokens.FontSize.body, weight: .medium))
            .foregroundStyle(tone)
    }
}

/// One account of the order: its number, its name and state, and who it hands off to.
struct HandoffRowView: View {
    let row: HandoffRow

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(verbatim: "\(row.number)")
                .font(.system(size: Tokens.FontSize.body, weight: .semibold))
                .foregroundStyle(Tokens.Palette.text2)
                .frame(width: 22, alignment: .trailing)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: row.name)
                    .font(.system(size: Tokens.FontSize.body, weight: .semibold))
                Text(verbatim: row.handsOff)
                    .font(.system(size: Tokens.FontSize.small))
                    .foregroundStyle(Tokens.Palette.text2)
            }
            Spacer(minLength: 0)
            Chip(text: row.state, tone: row.tone)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.Palette.surface, in: RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                .strokeBorder(Tokens.Palette.line, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}
