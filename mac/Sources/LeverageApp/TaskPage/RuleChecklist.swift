import SwiftUI

/// The task page's checklist: one line for each check, with "Let it through
/// once" and "Run it again" where the server allows them (RD-28, RD-49).
/// A reason is text a model wrote about the task: shown as plain text.
struct RuleChecklist: View {
    @Bindable var model: TaskPageModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(TaskPageCopy.sectionChecks.text)
                .font(.system(size: Tokens.FontSize.small, weight: .semibold))
                .foregroundStyle(Tokens.Palette.text2)
            ForEach(model.checks) { row in
                CheckLine(row: row, letThrough: { model.askToLetThrough(row.id) }, runAgain: {
                    Task { await model.runAgain(row.id) }
                })
            }
        }
    }
}

/// One check of the checklist. A greyed line is one that did not apply, was
/// not needed any more, or is a policy.
private struct CheckLine: View {
    let row: CheckRowContent
    let letThrough: () -> Void
    let runAgain: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: row.ruleName)
                    .font(.system(size: Tokens.FontSize.body, weight: .semibold))
                Spacer(minLength: 8)
                Text(verbatim: row.resultText)
                    .font(.system(size: Tokens.FontSize.body, weight: .medium))
            }
            Text(verbatim: details)
                .font(.system(size: Tokens.FontSize.small))
                .foregroundStyle(Tokens.Palette.text2)
            if let reason = row.reason, !reason.isEmpty {
                Text(verbatim: reason)
                    .font(.system(size: Tokens.FontSize.small))
                    .textSelection(.enabled)
            }
            if let overrideText = row.overrideText {
                Text(verbatim: overrideText)
                    .font(.system(size: Tokens.FontSize.small))
                    .foregroundStyle(Tokens.Palette.text2)
            }
            if row.canLetThrough || row.canRunAgain {
                HStack(spacing: 10) {
                    if row.canRunAgain {
                        Button(TaskPageCopy.runItAgain.text, action: runAgain)
                    }
                    if row.canLetThrough {
                        Button(TaskPageCopy.letThroughOnce.text, action: letThrough)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.Palette.inset, in: RoundedRectangle(cornerRadius: Tokens.Radius.control, style: .continuous))
        .opacity(row.isGreyed ? 0.6 : 1)
        .accessibilityElement(children: .contain)
    }

    /// When it ran, who checks it, what it does if it fails, how long it took and which wording it was.
    private var details: String {
        [row.momentText, row.checkerText, row.onFailText, row.timeText, row.wordingText]
            .compactMap { $0 }.joined(separator: " · ")
    }
}
