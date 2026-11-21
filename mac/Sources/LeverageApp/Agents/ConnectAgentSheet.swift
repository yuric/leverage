import LeverageKit
import SwiftUI

/// The Connect sheet (MA-12). Built by the Agents screen, which gives it the
/// way to close itself and to send the owner to Add credential; the shell's
/// `ScreenContext` is in the environment.
struct ConnectAgentSheet: View {
    let connected: @MainActor () -> Void
    let finish: @MainActor () -> Void
    let addLogin: @MainActor () -> Void
    @Environment(ScreenContext.self) private var context
    @State private var box = ScreenModelBox<ConnectAgentModel>()

    var body: some View {
        let model = box.model {
            ConnectAgentModel(
                api: context.owner, copy: Pasteboard.copy, onConnected: connected,
                apiURL: { [server = context.runtime.server] in await MCPSettings.liveAPIAddress(from: server) })
        }
        ConnectAgentForm(
            model: model,
            cancel: {
                model.finish()
                finish()
            },
            addLogin: addLogin
        )
        .task { await model.load() }
        .onDisappear { model.finish() }
    }
}

/// The sheet itself, drawn from its model.
struct ConnectAgentForm: View {
    @Bindable var model: ConnectAgentModel
    let cancel: () -> Void
    let addLogin: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(AgentsCopy.connectTitle.text)
                .font(.system(size: 20, weight: .semibold))
                .padding(.bottom, 14)
            ScrollView {
                Group {
                    switch model.phase {
                    case .editing, .connecting: fields.disabled(model.isBusy)
                    case .shown: shown
                    case .done: connectedOnLogin
                    }
                }
                .padding(.trailing, 6)
            }
            if let line = model.failure, model.phase == .editing || model.phase == .connecting {
                Text(verbatim: line)
                    .font(.system(size: Tokens.FontSize.body, weight: .medium))
                    .foregroundStyle(Tokens.Tone.stop.foreground)
                    .padding(.top, 8)
            }
            actions.padding(.top, 14)
        }
        .padding(Tokens.Spacing.sheet)
        .frame(width: 480, height: 640)
        .background(Tokens.Palette.sheet)
    }

    // MARK: the form

    private var fields: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker(AgentsCopy.connectTitle.text, selection: $model.mode) {
                Text(AgentsCopy.modeRunOnLogin.text).tag(ConnectAgentModel.Mode.runOnLogin)
                Text(AgentsCopy.modeOwn.text).tag(ConnectAgentModel.Mode.connectsOnItsOwn)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            FormField(label: AgentsCopy.roleLabel.text) {
                Picker(AgentsCopy.roleLabel.text, selection: $model.role) {
                    ForEach(ConnectAgentModel.roles, id: \.self) { role in
                        Text(AgentsCopy.role(role).text).tag(role)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            if model.mode == .runOnLogin {
                loginField
            } else {
                FormField(label: AgentsCopy.connectionLabel.text) {
                    Picker(AgentsCopy.connectionLabel.text, selection: $model.connection) {
                        ForEach(LandingPromptConnection.allCases, id: \.self) { connection in
                            Text(AgentsCopy.connection(connection).text).tag(connection)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                FormField(label: AgentsCopy.providerLabel.text) {
                    Picker(AgentsCopy.providerLabel.text, selection: $model.provider) {
                        ForEach(ProviderNames.logins, id: \.self) { provider in
                            Text(ProviderNames.name(provider)).tag(provider)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }

            FormField(label: AgentsCopy.nameLabel.text) {
                VStack(alignment: .leading, spacing: 4) {
                    TextField(AgentsCopy.namePlaceholder.text, text: $model.name)
                        .textFieldStyle(.roundedBorder)
                    if let line = model.nameLine {
                        Text(verbatim: line)
                            .font(.system(size: Tokens.FontSize.small, weight: .medium))
                            .foregroundStyle(Tokens.Tone.stop.foreground)
                    }
                }
            }
            FormField(label: AgentsCopy.modelLabel.text, hint: AgentsCopy.modelHint.text) {
                TextField(AgentsCopy.defaultModel.text, text: $model.modelName)
                    .textFieldStyle(.roundedBorder)
            }
            AgentStrengthPicker(selection: $model.strengthRank)
            if model.offersEffort {
                FormField(label: AgentsCopy.effortLabel.text, hint: AgentsCopy.effortHint.text) {
                    TextField(AgentsCopy.defaultEffort.text, text: $model.effort)
                        .textFieldStyle(.roundedBorder)
                }
            }
            if model.showsNotTestedNote {
                Text(AgentsCopy.notTestedForChecking.text)
                    .font(.system(size: Tokens.FontSize.small, weight: .medium))
                    .foregroundStyle(Tokens.Tone.wait.foreground)
            }
        }
    }

    @ViewBuilder
    private var loginField: some View {
        if model.logins.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(AgentsCopy.noLogins.text)
                    .font(.system(size: Tokens.FontSize.body))
                    .foregroundStyle(Tokens.Palette.text2)
                Button(AgentsCopy.addLogin.text, action: addLogin)
            }
        } else {
            FormField(
                label: AgentsCopy.loginLabel.text,
                hint: model.geminiHiddenForReviewer ? AgentsCopy.geminiHidden.text : nil
            ) {
                Picker(AgentsCopy.loginLabel.text, selection: $model.credentialID) {
                    ForEach(model.logins) { login in
                        Text(verbatim: login.label).tag(Optional(login.id))
                    }
                }
                .labelsHidden()
            }
        }
    }

    // MARK: after connecting

    private var connectedOnLogin: some View {
        Text(verbatim: model.name)
            .font(.system(size: Tokens.FontSize.body, weight: .semibold))
    }

    private var shown: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                sectionTitle(AgentsCopy.tokenTitle.text)
                if let token = model.shownToken {
                    Text(verbatim: token)
                        .font(.system(size: Tokens.FontSize.small, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            Tokens.Palette.inset,
                            in: RoundedRectangle(cornerRadius: Tokens.Radius.control, style: .continuous))
                    HStack(spacing: 10) {
                        Button(model.copiedToken ? AgentsCopy.copied.text : AgentsCopy.copy.text) { model.copyToken() }
                        Text(AgentsCopy.tokenNote.text)
                            .font(.system(size: Tokens.FontSize.small))
                            .foregroundStyle(Tokens.Palette.text2)
                    }
                } else if model.tokenGone {
                    Text(AgentsCopy.tokenGone.text)
                        .font(.system(size: Tokens.FontSize.body))
                        .foregroundStyle(Tokens.Tone.stop.foreground)
                }
            }
            if model.shownConnection == .mcp {
                mcpSettingsSection
            }
            VStack(alignment: .leading, spacing: 6) {
                sectionTitle(AgentsCopy.landingTitle.text)
                Text(AgentsCopy.landingNote.text)
                    .font(.system(size: Tokens.FontSize.small))
                    .foregroundStyle(Tokens.Palette.text2)
                landingBody
            }
        }
    }

    private var mcpSettingsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle(AgentsCopy.mcpSettingsTitle.text)
            if let settings = model.mcpConfiguration {
                Text(AgentsCopy.mcpSettingsNote.text)
                    .font(.system(size: Tokens.FontSize.small))
                    .foregroundStyle(Tokens.Palette.text2)
                Text(verbatim: settings.json)
                    .font(.system(size: Tokens.FontSize.small, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        Tokens.Palette.inset, in: RoundedRectangle(cornerRadius: Tokens.Radius.control, style: .continuous))
                Button(model.copiedMCPSettings ? AgentsCopy.copied.text : AgentsCopy.copy.text) { model.copyMCPSettings() }
                    .accessibilityLabel(AgentsCopy.copyMCPSettings.text)
                Text(verbatim: settings.plainText)
                    .font(.system(size: Tokens.FontSize.small, design: .monospaced))
                    .foregroundStyle(Tokens.Palette.text2)
                    .textSelection(.enabled)
            } else {
                Text(AgentsCopy.mcpSettingsUnavailable.text)
                    .font(.system(size: Tokens.FontSize.small))
                    .foregroundStyle(Tokens.Tone.stop.foreground)
            }
        }
    }

    @ViewBuilder
    private var landingBody: some View {
        switch model.landing {
        case .none:
            EmptyView()
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(AgentsCopy.landingLoading.text)
                    .font(.system(size: Tokens.FontSize.small))
                    .foregroundStyle(Tokens.Palette.text2)
            }
        case .ready(let text):
            Text(verbatim: text)
                .font(.system(size: Tokens.FontSize.small, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(8)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    Tokens.Palette.inset, in: RoundedRectangle(cornerRadius: Tokens.Radius.control, style: .continuous))
            Button(model.copiedPrompt ? AgentsCopy.copied.text : AgentsCopy.copy.text) { model.copyLandingPrompt() }
        case .failed(let line):
            Text(verbatim: line)
                .font(.system(size: Tokens.FontSize.body, weight: .medium))
                .foregroundStyle(Tokens.Tone.stop.foreground)
            Button(AgentsCopy.landingRetry.text) { Task { await model.retryLandingPrompt() } }
        }
    }

    // MARK: buttons

    private var actions: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)
            switch model.phase {
            case .editing, .connecting:
                if model.isBusy {
                    ProgressView().controlSize(.small)
                    Text(AgentsCopy.connecting.text)
                        .font(.system(size: Tokens.FontSize.small))
                        .foregroundStyle(Tokens.Palette.text2)
                }
                Button(AgentsCopy.cancel.text, action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button(AgentsCopy.connectButton.text) { Task { await model.connect() } }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canConnect)
            case .shown, .done:
                Button(AgentsCopy.done.text, action: cancel)
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.system(size: Tokens.FontSize.body, weight: .semibold))
    }
}
