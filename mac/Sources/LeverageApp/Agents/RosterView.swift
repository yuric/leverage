import LeverageKit
import SwiftUI

/// The Agents tab (MA-2): a list of the agents with Connect agent above it.
/// Built with no arguments; the shell puts its `ScreenContext` in the
/// environment. It draws its own Connect sheet, the Change sheet of an agent
/// and the confirmation before Remove.
struct RosterView: View {
    @Environment(ScreenContext.self) private var context
    @State private var box = ScreenModelBox<RosterModel>()
    @State private var isConnecting = false
    @State private var addingLoginAfterConnect = false

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
        .setupSheetOpen(isConnecting || model.changing != nil || model.newPrompt != nil)
        .sheet(isPresented: changing(model)) {
            if let change = model.changing {
                ChangeAgentForm(model: change, cancel: { model.cancelChange() })
            }
        }
        .sheet(isPresented: Binding(
            get: { model.newPrompt != nil },
            set: { if !$0 { model.closeNewPrompt() } }
        )) {
            if let prompt = model.newPrompt {
                NewLandingPromptSheet(model: prompt, dismiss: { model.closeNewPrompt() })
            }
        }
        .sheet(isPresented: $isConnecting, onDismiss: {
            if addingLoginAfterConnect {
                addingLoginAfterConnect = false
                context.navigator.presentAddCredential()
            }
        }) {
            ConnectAgentSheet(
                connected: { Task { await model.load() } },
                finish: {
                    isConnecting = false
                    Task { await model.load() }
                },
                addLogin: {
                    addingLoginAfterConnect = true
                    isConnecting = false
                }
            )
            .environment(context)
        }
    }
}

extension RosterView {
    /// The Change sheet shows while the roster model has one open.
    @MainActor
    fileprivate func changing(_ model: RosterModel) -> Binding<Bool> {
        Binding(get: { model.changing != nil }, set: { if !$0 { model.cancelChange() } })
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
                    .spotlightAnchor(.connectAgent)
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
        .setupSheetOpen(model.pendingRemoval != nil)
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
                if let note = row.notTestedNote {
                    Text(verbatim: note)
                        .font(.system(size: Tokens.FontSize.small))
                        .foregroundStyle(Tokens.Tone.wait.foreground)
                }
                if let note = row.pausedNote {
                    Text(verbatim: note)
                        .font(.system(size: Tokens.FontSize.small))
                        .foregroundStyle(Tokens.Palette.text2)
                }
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
                if row.canPause {
                    Button(AgentsCopy.pause.text) { Task { await model.pause(row.id) } }
                }
                if row.canResume {
                    Button(AgentsCopy.resume.text) { Task { await model.resume(row.id) } }
                }
                if row.canChange {
                    Button(AgentsCopy.change.text) { model.beginChange(row.id) }
                }
                if row.canIssueNewPrompt {
                    Menu(AgentsCopy.newPrompt.text) {
                        ForEach(LandingPromptConnection.allCases, id: \.self) { connection in
                            Button(AgentsCopy.connection(connection).text) {
                                model.prepareNewPrompt(row.id, connection: connection)
                            }
                        }
                    }
                }
                Button(AgentsCopy.remove.text) { model.askToRemove(row.id) }
            }
        }
    }
}
