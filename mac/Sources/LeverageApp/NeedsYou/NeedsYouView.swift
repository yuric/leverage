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
                openTask: { [navigator = context.navigator] in navigator.open(task: $0) })
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
    let model: NeedsYouModel

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
            if model.isWaitingForSignIn(row.id) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(NeedsYouCopy.signInWaiting.text)
                        .font(.system(size: Tokens.FontSize.small))
                        .foregroundStyle(Tokens.Palette.text2)
                }
            } else if model.confirmingCancel == row.id {
                HStack(spacing: 8) {
                    Text(NeedsYouCopy.cancelQuestion.text)
                        .font(.system(size: Tokens.FontSize.body, weight: .medium))
                    Button(NeedsYouCopy.cancelConfirm.text) { Task { await model.confirmCancel() } }
                    Button(NeedsYouCopy.cancelKeep.text) { model.dismissCancel() }
                }
            } else if !row.buttons.isEmpty {
                HStack(spacing: 8) {
                    ForEach(Array(row.buttons.enumerated()), id: \.element.id) { index, button in
                        if index == 0 {
                            Button(button.label) { run(button) }
                                .buttonStyle(PrimaryButtonStyle())
                        } else {
                            Button(button.label) { run(button) }
                        }
                    }
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

    private func run(_ button: NeedsYouButton) {
        Task { await model.perform(button.action, on: row.id) }
    }
}
