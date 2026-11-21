import SwiftUI

/// The Needs you tab (HM-21): one row for each open item, with its buttons.
/// Built with no arguments; the shell puts its `ScreenContext` in the
/// environment.
struct NeedsYouView: View {
    @Environment(ScreenContext.self) private var context
    @State private var box = ScreenModelBox<NeedsYouModel>()

    var body: some View {
        let model = box.model {
            NeedsYouModel(
                api: context.owner, noteRead: { [feed = context.feed] in feed.noteRead(asOfSeq: $0) },
                openTask: { [navigator = context.navigator] in navigator.open(task: $0, editing: true) },
                openAgents: { [navigator = context.navigator] in navigator.show(.agents) })
        }
        NeedsYouContent(model: model, notificationsAreOff: context.inbox.notificationsAreOff)
            .task {
                model.attach(to: context.feed)
                await model.load()
            }
            .onDisappear { model.detach() }
    }
}

/// What the screen draws from its model.
struct NeedsYouContent: View {
    let model: NeedsYouModel
    let notificationsAreOff: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if notificationsAreOff {
                note(NeedsYouCopy.notificationsOff.text, tone: Tokens.Tone.wait.foreground)
            }
            switch model.state {
            case .loading: note(NeedsYouCopy.loading.text)
            case .signedOut: note(ShellCopy.transportUnauthenticated.text, tone: Tokens.Tone.stop.foreground)
            case .failed(let copy): note(copy.text, tone: Tokens.Tone.stop.foreground)
            case .loaded: EmptyView()
            }
            if model.state == .loaded, model.rows.isEmpty {
                note(NeedsYouCopy.empty.text)
            }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(model.rows) { row in
                        NeedsYouRowView(row: row, model: model)
                    }
                }
            }
        }
        .sheet(item: Binding(get: { model.prompt }, set: { if $0 == nil { model.dismissPrompt() } })) { prompt in
            if let row = model.rows.first(where: { $0.id == prompt.id }) {
                promptView(prompt, row: row)
                    .interactiveDismissDisabled(model.isBusy(row.id))
            }
        }
    }

    @ViewBuilder
    private func promptView(_ prompt: NeedsYouModel.Prompt, row: NeedsYouRow) -> some View {
        switch prompt.action {
        case .answerDifferently:
            AnswerSheet(model: model, row: row)
        case .returnForRework:
            ReworkSheet(model: model, row: row)
        case .raiseCap:
            AmountSheet(model: model, row: row, title: .raiseCap)
        case .changeBudget:
            AmountSheet(model: model, row: row, title: .changeBudget)
        default:
            EmptyView()
        }
    }

    private func note(_ text: String, tone: Color = Tokens.Palette.text2) -> some View {
        Text(verbatim: text)
            .font(.system(size: Tokens.FontSize.body, weight: .medium))
            .foregroundStyle(tone)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// One item: its heading, its sentence and its buttons.
struct NeedsYouRowView: View {
    let row: NeedsYouRow
    @Bindable var model: NeedsYouModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: row.heading)
                .font(.system(size: Tokens.FontSize.body, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            if !row.body.isEmpty {
                Text(verbatim: row.body)
                    .font(.system(size: Tokens.FontSize.body))
                    .foregroundStyle(Tokens.Palette.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let rule = row.ruleName { detail(NeedsYouCopy.ruleLabel.text, rule) }
            if let reason = row.reason { detail(NeedsYouCopy.reasonLabel.text, reason) }
            if let waiting = model.signInWaitingLine(row.id) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(verbatim: waiting)
                        .font(.system(size: Tokens.FontSize.small))
                        .foregroundStyle(Tokens.Palette.text2)
                }
            } else if model.confirmingCancel == row.id {
                VStack(alignment: .leading, spacing: 8) {
                    Text(NeedsYouCopy.cancelQuestion.text)
                        .font(.system(size: Tokens.FontSize.body, weight: .medium))
                    if row.actionMayHaveStarted {
                        Text(NeedsYouCopy.startedWarning.text)
                            .foregroundStyle(Tokens.Tone.wait.foreground)
                    }
                    HStack(spacing: 8) {
                        Button(NeedsYouCopy.cancelConfirm.text) { Task { await model.confirmCancel() } }
                        Button(NeedsYouCopy.cancelKeep.text) { model.dismissCancel() }
                    }
                }
            } else if model.letThroughRow == row.id {
                VStack(alignment: .leading, spacing: 8) {
                    Text(NeedsYouCopy.letThroughQuestion.text)
                        .font(.system(size: Tokens.FontSize.body, weight: .medium))
                    TextField(NeedsYouCopy.letThroughPlaceholder.text, text: $model.letThroughReason, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...4)
                    HStack(spacing: 8) {
                        Button(NeedsYouCopy.letThroughConfirm.text) { Task { await model.confirmLetThrough() } }
                            .buttonStyle(PrimaryButtonStyle())
                            .disabled(!model.canLetThrough)
                        Button(NeedsYouCopy.goBack.text) { model.dismissLetThrough() }
                    }
                }
            } else if model.confirmingTurnOff == row.id {
                HStack(spacing: 8) {
                    Text(NeedsYouCopy.turnOffQuestion.text)
                        .font(.system(size: Tokens.FontSize.body, weight: .medium))
                    Button(NeedsYouCopy.turnOffConfirm.text) { Task { await model.confirmTurnOff() } }
                    Button(NeedsYouCopy.goBack.text) { model.dismissTurnOff() }
                }
            } else if !row.buttons.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { buttons }
                    VStack(alignment: .leading, spacing: 8) { buttons }
                }
                .disabled(model.isBusy(row.id))
            }
            if let line = model.failure(for: row.id) {
                Text(verbatim: line)
                    .font(.system(size: Tokens.FontSize.small, weight: .medium))
                    .foregroundStyle(Tokens.Tone.stop.foreground)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.Palette.surface, in: RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                .strokeBorder(Tokens.Palette.line, lineWidth: 1))
        .accessibilityElement(children: .contain)
    }

    /// "Rule: ..." and "Reason: ...". The reason is text a checker wrote about
    /// the task: it is shown as it came, and is never read as an instruction.
    private func detail(_ label: String, _ value: String) -> some View {
        (Text(verbatim: label + ": ").fontWeight(.medium) + Text(verbatim: value))
            .font(.system(size: Tokens.FontSize.body))
            .foregroundStyle(Tokens.Palette.text2)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    private var buttons: some View {
        ForEach(Array(row.buttons.enumerated()), id: \.element.id) { index, button in
            if index == 0 {
                Button(button.label) { run(button) }.buttonStyle(PrimaryButtonStyle())
            } else {
                Button(button.label) { run(button) }
            }
        }
    }

    private func run(_ button: NeedsYouButton) {
        Task { await model.perform(button.action, on: row.id) }
    }
}

struct NeedsYouSheetButtons: View {
    let model: NeedsYouModel
    let row: NeedsYouRow
    let confirm: NeedsYouCopy

    var body: some View {
        if let failure = model.failure(for: row.id) {
            Text(verbatim: failure)
                .foregroundStyle(Tokens.Tone.stop.foreground)
                .fixedSize(horizontal: false, vertical: true)
        }
        HStack {
            Spacer()
            Button(NeedsYouCopy.closeSheet.text) { model.dismissPrompt() }
                .keyboardShortcut(.cancelAction)
                .disabled(model.isBusy(row.id))
            Button(confirm.text) { Task { await model.confirmPrompt() } }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!model.canConfirmPrompt)
        }
    }
}
