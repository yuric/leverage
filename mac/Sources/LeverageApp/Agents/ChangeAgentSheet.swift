import LeverageKit
import SwiftUI

/// The Change sheet of an agent (HM-51), drawn from its model. The Agents
/// screen presents it while its roster model has one open, and closes it when
/// the change was saved or the owner cancels.
struct ChangeAgentForm: View {
    @Bindable var model: ChangeAgentModel
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: model.title)
                .font(.system(size: 20, weight: .semibold))
                .padding(.bottom, 14)
            ScrollView {
                fields.padding(.trailing, 6)
            }
            if let line = model.failure {
                Text(verbatim: line)
                    .font(.system(size: Tokens.FontSize.body, weight: .medium))
                    .foregroundStyle(Tokens.Tone.stop.foreground)
                    .padding(.top, 8)
            }
            actions.padding(.top, 14)
        }
        .padding(Tokens.Spacing.sheet)
        .frame(width: 460, height: 560)
        .background(Tokens.Palette.sheet)
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: 14) {
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
            if model.offersLogin {
                FormField(
                    label: AgentsCopy.loginLabel.text,
                    hint: model.geminiHiddenForReviewer ? AgentsCopy.geminiHidden.text : nil
                ) {
                    Picker(AgentsCopy.loginLabel.text, selection: $model.credentialID) {
                        ForEach(model.loginChoices) { login in
                            Text(verbatim: login.label).tag(Optional(login.id))
                        }
                    }
                    .labelsHidden()
                }
            }
            if let provider = model.modelProvider {
                AgentModelPicker(provider: provider, existingModel: model.existingModel, selection: $model.modelName)
            }
            AgentStrengthPicker(selection: $model.strengthRank)
            if model.offersEffort {
                FormField(label: AgentsCopy.effortLabel.text, hint: AgentsCopy.effortHint.text) {
                    TextField(AgentsCopy.defaultEffort.text, text: $model.effort)
                        .textFieldStyle(.roundedBorder)
                }
            }
            FormField(label: AgentsCopy.changeEnabledLabel.text, hint: model.enabledNote) {
                Toggle(AgentsCopy.changeEnabledLabel.text, isOn: $model.enabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            Text(AgentsCopy.changeNote.text)
                .font(.system(size: Tokens.FontSize.small))
                .foregroundStyle(Tokens.Palette.text2)
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)
            if model.isBusy {
                ProgressView().controlSize(.small)
                Text(AgentsCopy.changeSaving.text)
                    .font(.system(size: Tokens.FontSize.small))
                    .foregroundStyle(Tokens.Palette.text2)
            }
            Button(AgentsCopy.cancel.text, action: cancel)
                .keyboardShortcut(.cancelAction)
            Button(AgentsCopy.changeSave.text) { Task { await model.save() } }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canSave)
        }
    }
}

struct AgentStrengthPicker: View {
    @Binding var selection: Int

    var body: some View {
        FormField(label: AgentsCopy.strengthLabel.text) {
            Picker(AgentsCopy.strengthLabel.text, selection: $selection) {
                ForEach(AgentStrength.allCases, id: \.self) { strength in
                    Text(strength.copy.text).tag(strength.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }
}
