import SwiftUI

/// What setup puts at the top of the task board: the line naming the task
/// the assistant sent, and the checklist card. Each shows only when it
/// applies; with neither, it draws nothing.
struct SetupBoardHeader: View {
    let setup: SetupModel
    let cards: [BoardCard]

    var body: some View {
        if let line = Self.sentTaskLine(setup) {
            SentTaskLine(text: line, close: { setup.dismissSentTaskLine() })
        }
        if Self.showsChecklist(setup) {
            SetupChecklistCard(
                content: SetupChecklistContent(facts: setup.facts, cards: cards),
                showMe: { setup.showMe() }, hide: { setup.hideChecklist() }, finish: { setup.finishChecklist() })
        }
    }

    static func showsChecklist(_ setup: SetupModel) -> Bool { setup.presentation == .checklist }

    /// The sentence naming the task the assistant sent; nil once it is closed.
    static func sentTaskLine(_ setup: SetupModel) -> String? {
        setup.sentTaskTitle.map { SetupChecklistCopy.sentTaskLine.filled(["task": $0]) }
    }
}

/// The checklist card, or the finished strip once all four steps are done.
struct SetupChecklistCard: View {
    let content: SetupChecklistContent
    let showMe: () -> Void
    let hide: () -> Void
    let finish: () -> Void

    var body: some View {
        if content.isFinished {
            finishedStrip
        } else {
            card
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: content.title)
                        .font(.system(size: Tokens.FontSize.head, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text(verbatim: content.subtitle)
                        .font(.system(size: Tokens.FontSize.small))
                        .foregroundStyle(Tokens.Palette.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                SetupMeter(doneCount: content.doneCount, label: content.meterLabel)
                    .frame(minWidth: 60, maxWidth: 120)
                    .frame(height: 6)
                Text(verbatim: content.progress)
                    .font(.system(size: Tokens.FontSize.small))
                    .foregroundStyle(Tokens.Palette.text2)
                    .fixedSize()
                    .accessibilityHidden(true)
                Button(SetupChecklistCopy.hide.text, action: hide)
                    .buttonStyle(QuietButtonStyle())
                    .fixedSize()
            }
            HStack(alignment: .top, spacing: 10) {
                ForEach(content.steps) { step in
                    SetupStepView(step: step, showMe: showMe)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(Tokens.Palette.surface, in: RoundedRectangle(cornerRadius: Tokens.Radius.nav, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.Radius.nav, style: .continuous)
                .strokeBorder(Tokens.Palette.line, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: content.title))
    }

    private var finishedStrip: some View {
        HStack(spacing: 12) {
            (Text(verbatim: content.finishedTitle).fontWeight(.semibold) + Text(verbatim: " ")
                + Text(verbatim: content.finishedBody))
                .font(.system(size: Tokens.FontSize.body))
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(SetupChecklistCopy.finishSetup.text, action: finish)
                .buttonStyle(SmallButtonStyle())
        }
        .foregroundStyle(Tokens.Tone.done.foreground)
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .background(
            Tokens.Tone.done.background, in: RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

/// One of the four steps.
struct SetupStepView: View {
    let step: SetupChecklistContent.Step
    let showMe: () -> Void

    private var isCurrent: Bool { step.state == .current }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                mark
                Text(verbatim: step.title)
                    .font(.system(size: Tokens.FontSize.body, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(verbatim: step.body)
                .font(.system(size: Tokens.FontSize.small))
                .foregroundStyle(Tokens.Palette.text2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            foot
                .frame(minHeight: 28, alignment: .leading)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            isCurrent ? Tokens.Palette.surface : Tokens.Palette.inset,
            in: RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
        )
        .overlay {
            if isCurrent {
                RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                    .strokeBorder(Tokens.Palette.primary, lineWidth: 1)
                RoundedRectangle(cornerRadius: Tokens.Radius.card + 3, style: .continuous)
                    .strokeBorder(Tokens.Palette.primary.opacity(0.22), lineWidth: 3)
                    .padding(-3)
            }
        }
        .opacity(step.state == .later ? 0.62 : 1)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    private var mark: some View {
        ZStack {
            switch step.state {
            case .done:
                Circle().fill(Tokens.Tone.done.background)
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Tokens.Tone.done.foreground)
            case .current:
                Circle().fill(Tokens.Palette.primary)
                Text(verbatim: String(step.step.rawValue))
                    .font(.system(size: Tokens.FontSize.small, weight: .bold))
                    .foregroundStyle(Tokens.Palette.primaryForeground)
            case .later:
                Circle().strokeBorder(Tokens.Palette.field, lineWidth: 1.5)
                Text(verbatim: String(step.step.rawValue))
                    .font(.system(size: Tokens.FontSize.small, weight: .bold))
                    .foregroundStyle(Tokens.Palette.text2)
            }
        }
        .frame(width: 22, height: 22)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var foot: some View {
        switch step.foot {
        case .done:
            Chip(text: BoardCopy.chipDone.text, tone: .done)
        case .showMe:
            Button(SetupChecklistCopy.showMe.text, action: showMe)
                .buttonStyle(TintButtonStyle())
        case .live(let line):
            LiveLine(text: line)
        case .none:
            EmptyView()
        }
    }
}

/// The running task's line, with a dot that blinks unless Reduce Motion is on.
private struct LiveLine: View {
    let text: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .frame(width: 8, height: 8)
                .opacity(dim ? 0.25 : 1)
                .accessibilityHidden(true)
            Text(verbatim: text)
                .font(.system(size: Tokens.FontSize.small, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Tokens.Tone.info.foreground)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) { dim = true }
        }
    }
}

/// How far setup has come, as a thin bar.
struct SetupMeter: View {
    let doneCount: Int
    let label: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Tokens.Palette.inset)
                Capsule().fill(Tokens.Palette.primary)
                    .frame(width: proxy.size.width * CGFloat(min(max(doneCount, 0), 4)) / 4)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: doneCount)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: label))
    }
}

/// The line on the task board after the assistant sent a first task.
struct SentTaskLine: View {
    let text: String
    let close: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .accessibilityHidden(true)
            Text(verbatim: text)
                .font(.system(size: Tokens.FontSize.body))
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: Tokens.FontSize.small, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(SetupChecklistCopy.close.text))
        }
        .foregroundStyle(Tokens.Tone.info.foreground)
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(Tokens.Tone.info.background, in: RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

/// Setup's progress in the side pane, above the health line. A click shows
/// the task board, where the checklist is.
struct SetupProgressPill: View {
    let doneCount: Int
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(SetupChecklistCopy.sidePaneTitle.text)
                        .fontWeight(.semibold)
                    Spacer(minLength: 0)
                    Text(verbatim: SetupChecklistContent.progress(doneCount))
                        .fontWeight(.medium)
                        .foregroundStyle(Tokens.Palette.text2)
                }
                SetupMeter(doneCount: doneCount, label: "")
                    .frame(height: 4)
                    .accessibilityHidden(true)
            }
            .font(.system(size: Tokens.FontSize.small))
            .foregroundStyle(Tokens.Palette.text)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Tokens.Palette.surface, in: RoundedRectangle(cornerRadius: Tokens.Radius.control, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Tokens.Radius.control, style: .continuous)
                    .strokeBorder(Tokens.Palette.line, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    static func shows(_ setup: SetupModel) -> Bool { setup.presentation == .checklist }

    /// The pill's click: the task board, with no task's page open.
    static func open(_ navigator: Navigator) { navigator.show(.board) }
}

/// A small button on the tone of what it sits on: Show me.
private struct TintButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: Tokens.FontSize.small, weight: .semibold))
            .padding(.horizontal, 10)
            .frame(minHeight: 28)
            .foregroundStyle(Tokens.Tone.info.foreground)
            .background(
                Tokens.Tone.info.background.opacity(configuration.isPressed ? 0.8 : 1),
                in: RoundedRectangle(cornerRadius: Tokens.Radius.control, style: .continuous))
            .contentShape(Rectangle())
    }
}

/// A small plain button with a border: Finish setup on the finished strip.
private struct SmallButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: Tokens.FontSize.small, weight: .medium))
            .padding(.horizontal, 10)
            .frame(minHeight: 28)
            .foregroundStyle(Tokens.Palette.text)
            .background(
                Tokens.Palette.control.opacity(configuration.isPressed ? 0.8 : 1),
                in: RoundedRectangle(cornerRadius: Tokens.Radius.control, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Tokens.Radius.control, style: .continuous)
                    .strokeBorder(Tokens.Palette.line, lineWidth: 1))
            .contentShape(Rectangle())
    }
}

/// A quiet text button that does not compete with the card: Hide this.
private struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: Tokens.FontSize.small, weight: .medium))
            .foregroundStyle(Tokens.Palette.text2.opacity(configuration.isPressed ? 0.6 : 1))
            .padding(.vertical, 4)
            .contentShape(Rectangle())
    }
}
