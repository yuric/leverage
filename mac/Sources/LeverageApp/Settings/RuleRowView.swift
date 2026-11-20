import SwiftUI

/// One rule: its switch, its name, when it runs, who it applies to, who
/// checks it, its sentence or instruction, and how it has run.
struct RuleRowView: View {
    let line: RuleLine
    let isChanging: Bool
    let turn: (Bool) -> Void
    let change: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle(isOn: Binding(get: { line.isOn }, set: { turn($0) })) {
                Text(verbatim: (line.isOn ? RulesCopy.turnOff : RulesCopy.turnOn).filled(["name": line.name]))
            }
            .labelsHidden()
            .toggleStyle(.switch)
            .disabled(isChanging)
            .padding(.top, 1)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: line.name)
                        .font(.system(size: Tokens.FontSize.body, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    if let notActing = line.notActing {
                        Chip(text: notActing, tone: .wait)
                    }
                    Spacer(minLength: 0)
                    Button(RulesCopy.change.text, action: change)
                        .buttonStyle(.link)
                        .font(.system(size: Tokens.FontSize.small, weight: .semibold))
                }
                if !line.detail.isEmpty {
                    Text(verbatim: line.detail)
                        .font(.system(size: Tokens.FontSize.body))
                        .foregroundStyle(Tokens.Palette.text2)
                        .lineLimit(line.detailIsInstruction ? 4 : nil)
                        .fixedSize(horizontal: false, vertical: true)
                }
                facts
                Text(verbatim: line.counts)
                    .font(.system(size: Tokens.FontSize.small))
                    .foregroundStyle(Tokens.Palette.text2)
                Text(verbatim: line.wording)
                    .font(.system(size: Tokens.FontSize.small))
                    .foregroundStyle(Tokens.Palette.text2)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.Palette.surface, in: RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                .strokeBorder(Tokens.Palette.line, lineWidth: 1))
        .opacity(line.isOn ? 1 : 0.7)
    }

    private var facts: some View {
        HStack(alignment: .top, spacing: 18) {
            fact(RulesCopy.whenItRuns.text, line.whenItRuns)
            fact(RulesCopy.appliesTo.text, line.appliesTo)
            fact(RulesCopy.checkedBy.text, line.checkedBy)
            if let ifItFails = line.ifItFails {
                fact(RulesCopy.ifItFails.text, ifItFails)
            }
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: label)
                .font(.system(size: Tokens.FontSize.badge, weight: .semibold))
                .foregroundStyle(Tokens.Palette.text2)
            Text(verbatim: value)
                .font(.system(size: Tokens.FontSize.small))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
