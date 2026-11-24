import SwiftUI

/// The contract editor of a task (HM-49): the Add task form filled in, with
/// Save and Save and send to agents. Presented by the task page.
struct EditContractSheet: View {
    @Bindable var model: EditContractModel
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(AddTaskCopy.changeTaskTitle.text)
                .font(.system(size: 20, weight: .semibold))
                .padding(.bottom, 10)
            if let warning = model.warning {
                Text(warning.text)
                    .font(.system(size: Tokens.FontSize.body))
                    .foregroundStyle(Tokens.Palette.text2)
                    .padding(.bottom, 10)
            }
            ScrollView {
                EditContractFields(model: model)
                    .padding(.trailing, 6)
            }
            if let failure = model.failure {
                VStack(alignment: .leading, spacing: 4) {
                    if model.savedWithoutSending {
                        Text(AddTaskCopy.savedNotSent.text)
                    }
                    Text(failure.text)
                }
                .font(.system(size: Tokens.FontSize.body, weight: .medium))
                .foregroundStyle(Tokens.Tone.stop.foreground)
                .padding(.top, 8)
            }
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                if model.isBusy {
                    ProgressView().controlSize(.small)
                    Text(AddTaskCopy.saving.text)
                        .font(.system(size: Tokens.FontSize.small))
                        .foregroundStyle(Tokens.Palette.text2)
                }
                Button(AddTaskCopy.cancel.text, action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button(AddTaskCopy.saveChanges.text) {
                    Task { await model.save() }
                }
                .disabled(!model.canSave)
                Button(AddTaskCopy.saveAndSend.text) {
                    Task { await model.saveAndSend() }
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canSave)
            }
            .padding(.top, 14)
        }
        .padding(Tokens.Spacing.sheet)
        .frame(width: 480, height: 640)
        .background(Tokens.Palette.sheet)
    }
}

/// The fields of the editor, one under another: Add task's, without Priority,
/// which Edit contract does not carry.
struct EditContractFields: View {
    @Bindable var model: EditContractModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            FormField(label: AddTaskCopy.titleLabel.text) {
                TextField(AddTaskCopy.titlePlaceholder.text, text: $model.draft.title)
                    .textFieldStyle(.roundedBorder)
            }
            FormField(label: AddTaskCopy.criteriaLabel.text, hint: AddTaskCopy.criteriaHint.text) {
                PlaceholderEditor(text: $model.draft.criteriaText, placeholder: AddTaskCopy.criteriaPlaceholder.text)
            }
            FormField(label: AddTaskCopy.detailsLabel.text) {
                PlaceholderEditor(
                    text: $model.draft.details, placeholder: AddTaskCopy.detailsPlaceholder.text, minHeight: 48)
            }
            WorkReferenceField(reference: $model.draft.workReference, projectID: model.projectID)
        }
    }
}
