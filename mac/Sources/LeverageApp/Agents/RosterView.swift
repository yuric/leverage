import SwiftUI

/// The Agents tab (MA-2): a list of the agents with Connect agent above it.
/// Built with no arguments; the shell puts its `ScreenContext` in the
/// environment. It draws its own Connect sheet and the confirmation before
/// Remove.
struct RosterView: View {
    @Environment(ScreenContext.self) private var context
    @State private var box = ScreenModelBox<RosterModel>()
    @State private var isConnecting = false

    var body: some View {
        let model = box.model {
            RosterModel(
                api: context.owner, noteRead: { [feed = context.feed] in feed.noteRead(asOfSeq: $0) },
                copy: Pasteboard.copy)
        }
        RosterContent(
            model: model, connect: { isConnecting = true }, openCredentials: { context.navigator.show(.credentials) }
        )
        .task {
            model.attach(to: context.feed)
            await model.keepCurrent()
        }
        .onDisappear { model.detach() }
        .sheet(isPresented: $isConnecting) {
            ConnectAgentSheet(
                connected: { Task { await model.load() } },
                finish: {
                    isConnecting = false
                    Task { await model.load() }
                },
                addLogin: {
                    isConnecting = false
                    context.navigator.show(.credentials)
                }
            )
            .environment(context)
        }
    }
}

/// What the screen draws from its model.
struct RosterContent: View {
    let model: RosterModel
    let connect: () -> Void
    let openCredentials: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                notice
                Spacer(minLength: 0)
                Button(AgentsCopy.connect.text, action: connect)
                    .buttonStyle(PrimaryButtonStyle())
            }
            if model.state == .loaded, model.rows.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(AgentsCopy.empty.text)
                        .font(.system(size: Tokens.FontSize.body))
                        .foregroundStyle(Tokens.Palette.text2)
                    Button(AgentsCopy.addLogin.text, action: openCredentials)
                }
            }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(model.rows) { row in
                        RosterRowView(row: row, model: model)
                    }
                }
            }
        }
        .confirmationDialog(
            model.pendingRemoval?.title ?? "", isPresented: removing, titleVisibility: .visible
        ) {
            Button(AgentsCopy.removeConfirm.text, role: .destructive) {
                Task { await model.confirmRemoval() }
            }
            Button(AgentsCopy.cancel.text, role: .cancel) { model.cancelRemoval() }
        } message: {
            Text(verbatim: model.pendingRemoval?.message ?? "")
        }
    }

    private var removing: Binding<Bool> {
        Binding(
            get: { model.pendingRemoval != nil },
            set: { if !$0 { model.cancelRemoval() } })
    }

    @ViewBuilder
    private var notice: some View {
        switch model.state {
        case .loading:
            Text(AgentsCopy.loading.text)
                .font(.system(size: Tokens.FontSize.body))
                .foregroundStyle(Tokens.Palette.text2)
        case .signedOut:
            Text(ShellCopy.transportUnauthenticated.text)
                .font(.system(size: Tokens.FontSize.body, weight: .medium))
                .foregroundStyle(Tokens.Tone.stop.foreground)
        case .failed(let copy):
            Text(copy.text)
                .font(.system(size: Tokens.FontSize.body, weight: .medium))
                .foregroundStyle(Tokens.Tone.stop.foreground)
        case .loaded:
            EmptyView()
        }
    }
}

/// One agent: its name and what it is doing, its details, and its buttons.
struct RosterRowView: View {
    let row: RosterRow
    let model: RosterModel

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: row.name)
                    .font(.system(size: Tokens.FontSize.body, weight: .semibold))
                Text(verbatim: row.roleLine)
                    .font(.system(size: Tokens.FontSize.body))
                Text(verbatim: row.detailLine)
                    .font(.system(size: Tokens.FontSize.small))
                    .foregroundStyle(Tokens.Palette.text2)
                if let login = row.loginLine {
                    Text(verbatim: login)
                        .font(.system(size: Tokens.FontSize.small))
                        .foregroundStyle(Tokens.Palette.text2)
                }
                Text(verbatim: row.lastPolledLine)
                    .font(.system(size: Tokens.FontSize.small))
                    .foregroundStyle(Tokens.Palette.text2)
                if let line = model.failure(for: row.id) {
                    Text(verbatim: line)
                        .font(.system(size: Tokens.FontSize.small, weight: .medium))
                        .foregroundStyle(Tokens.Tone.stop.foreground)
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 8) {
                if let chip = row.runChip {
                    Chip(text: chip.text, tone: chip.tone)
                }
                buttons
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

    @ViewBuilder
    private var buttons: some View {
        if model.isBusy(row.id) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                if let working = model.working[row.id] {
                    Text(working.text)
                        .font(.system(size: Tokens.FontSize.small))
                        .foregroundStyle(Tokens.Palette.text2)
                }
            }
        } else {
            HStack(spacing: 8) {
                if row.canStart {
                    Button(AgentsCopy.start.text) { Task { await model.start(row.id) } }
                }
                if row.canStop {
                    Button(AgentsCopy.stop.text) { Task { await model.stop(row.id) } }
                }
                if row.canCopyLandingPrompt {
                    Button(model.copiedPrompt == row.id ? AgentsCopy.copied.text : AgentsCopy.copyLandingPrompt.text) {
                        Task { await model.copyLandingPrompt(row.id) }
                    }
                }
                Button(AgentsCopy.remove.text) { model.askToRemove(row.id) }
            }
        }
    }
}
