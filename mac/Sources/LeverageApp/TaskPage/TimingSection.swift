import SwiftUI

/// The task page's Timing section: each step's time in order, the total from
/// the move to Backlog, and the time before the task left Ideas apart, after
/// the total (RD-28; PRD rule 7).
struct TimingSection: View {
    let timing: TimingContent

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(TaskPageCopy.sectionTiming.text)
                .font(.system(size: Tokens.FontSize.small, weight: .semibold))
                .foregroundStyle(Tokens.Palette.text2)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(timing.rows) { row in
                    line(row.name, time: row.durationText, open: row.isOpen)
                }
                Divider()
                line(TaskPageCopy.timingTotal.text, time: timing.totalText, open: false, bold: true)
                if let ideas = timing.beforeIdeas {
                    line(TaskPageCopy.timingBeforeIdeas.text, time: ideas.durationText, open: false)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func line(_ name: String, time: String, open: Bool, bold: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: name)
                .font(.system(size: Tokens.FontSize.body, weight: bold ? .semibold : .regular))
            Spacer(minLength: 8)
            Text(verbatim: time)
                .font(.system(size: Tokens.FontSize.body, weight: bold ? .semibold : .regular))
                .monospacedDigit()
            if open {
                Text(TaskPageCopy.timingSoFar.text)
                    .font(.system(size: Tokens.FontSize.small))
                    .foregroundStyle(Tokens.Palette.text2)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
