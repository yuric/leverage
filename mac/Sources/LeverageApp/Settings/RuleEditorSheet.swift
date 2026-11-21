import LeverageKit
import SwiftUI

/// The sheet that adds a rule or changes one (RD-4, RD-6). Presented by the
/// Rules screen.
struct RuleEditorSheet: View {
    @Bindable var model: RuleEditorModel
    let cancel: () -> Void
    @State private var confirmingRemove = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text((model.isAdding ? RulesCopy.addTitle : RulesCopy.changeTitle).text)
                .font(.system(size: 20, weight: .semibold))
                .padding(.bottom, 14)
            ScrollView {
                RuleEditorFields(model: model)
                    .padding(.trailing, 6)
            }
            if let failure = model.failure {
                Text(verbatim: failure.text)
                    .font(.system(size: Tokens.FontSize.body, weight: .medium))
                    .foregroundStyle(Tokens.Tone.stop.foreground)
                    .padding(.top, 8)
            }
            if confirmingRemove {
                HStack(spacing: 10) {
                    Text(verbatim: RulesCopy.removeAsk.text)
                        .font(.system(size: Tokens.FontSize.body))
                    Spacer(minLength: 0)
                    Button(RulesCopy.removeKeep.text) { confirmingRemove = false }
                    Button(RulesCopy.removeRule.text) {
                        confirmingRemove = false
                        Task { await model.remove() }
                    }
                }
                .padding(.top, 10)
            }
            HStack(spacing: 10) {
                if model.canRevert {
                    Button(RulesCopy.revertToDefault.text) { Task { await model.revert() } }
                        .disabled(model.isBusy)
                }
                if model.canRemove {
                    Button(RulesCopy.removeRule.text) { confirmingRemove = true }
                        .disabled(model.isBusy)
                }
                Spacer(minLength: 0)
                if model.isBusy {
                    ProgressView().controlSize(.small)
                    Text(verbatim: RulesCopy.saving.text)
                        .font(.system(size: Tokens.FontSize.small))
                        .foregroundStyle(Tokens.Palette.text2)
                }
                Button(RulesCopy.cancel.text, action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button((model.isAdding ? RulesCopy.add : RulesCopy.save).text) {
                    Task { await model.save() }
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canSave)
            }
            .padding(.top, 14)
        }
        .padding(Tokens.Spacing.sheet)
        .frame(width: 480, height: 560)
        .background(Tokens.Palette.sheet)
    }
}

/// The fields of the sheet, one under another; each shows only where the rule
/// has it.
struct RuleEditorFields: View {
    @Bindable var model: RuleEditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            FormField(label: RulesCopy.nameLabel.text) {
                if model.canEditName {
                    TextField(RulesCopy.namePlaceholder.text, text: $model.name)
                        .textFieldStyle(.roundedBorder)
                } else {
                    Text(verbatim: model.name)
                        .font(.system(size: Tokens.FontSize.body))
                }
            }
            if model.showsHook {
                FormField(label: RulesCopy.momentLabel.text) {
                    Picker(selection: $model.hook) {
                        ForEach(RuleEditorModel.offeredHooks, id: \.self) { hook in
                            Text(verbatim: hook.momentName).tag(hook)
                        }
                    } label: {
                        Text(verbatim: RulesCopy.momentLabel.text)
                    }
                    .labelsHidden()
                }
            }
            if model.showsInstruction {
                FormField(label: RulesCopy.instructionLabel.text) {
                    PlaceholderEditor(
                        text: $model.instruction, placeholder: RulesCopy.instructionPlaceholder.text, minHeight: 140)
                }
            }
            if !model.parameters.isEmpty {
                FormField(label: RulesCopy.numbersLabel.text) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach($model.parameters) { $field in
                            HStack(spacing: 10) {
                                Text(verbatim: field.label)
                                    .font(.system(size: Tokens.FontSize.body))
                                Spacer(minLength: 0)
                                TextField(field.label, text: $field.text)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 70)
                            }
                        }
                    }
                }
            }
            if model.showsScope {
                FormField(label: RulesCopy.scopeLabel.text) {
                    Picker(selection: $model.scopeKind) {
                        ForEach(RuleEditorModel.offeredScopes, id: \.self) { kind in
                            Text(verbatim: RulesCopy.scopeWords(kind).text).tag(kind)
                        }
                    } label: {
                        Text(verbatim: RulesCopy.scopeLabel.text)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }
            }
            if model.showsOnFail {
                FormField(label: RulesCopy.onFailLabel.text) {
                    Picker(selection: $model.onFail) {
                        Text(verbatim: RulesCopy.onFailBlock.text).tag(RuleOnFail?.some(.block))
                        Text(verbatim: RulesCopy.onFailWarn.text).tag(RuleOnFail?.some(.warn))
                    } label: {
                        Text(verbatim: RulesCopy.onFailLabel.text)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }
            }
        }
    }
}
