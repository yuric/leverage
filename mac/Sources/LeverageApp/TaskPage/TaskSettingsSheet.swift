import LeverageKit
import SwiftUI

struct TaskSettingsSheet: View {
    @Bindable var model: TaskSettingsModel
    let projects: [Project]
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(TaskPageCopy.taskSettings.text)
                .font(.system(size: 20, weight: .semibold))

            VStack(alignment: .leading, spacing: 14) {
                Picker(AddTaskCopy.priorityLabel.text, selection: $model.priority) {
                    Text(AddTaskCopy.priorityLow.text).tag(Priority.low)
                    Text(AddTaskCopy.priorityNormal.text).tag(Priority.normal)
                    Text(AddTaskCopy.priorityHigh.text).tag(Priority.high)
                }
                Picker(TaskPageCopy.taskSettingsProject.text, selection: $model.projectID) {
                    Text(TaskPageCopy.noProject.text).tag(nil as UUID?)
                    if let id = model.projectID, !projects.contains(where: { $0.id == id }) {
                        Text(TaskPageCopy.currentProject.text).tag(Optional(id))
                    }
                    ForEach(projects, id: \.id) { project in
                        Text(verbatim: project.name).tag(Optional(project.id))
                    }
                }
                FormField(label: TaskPageCopy.spendingLimit.text) {
                    TextField(TaskPageCopy.noSpendingLimit.text, text: $model.capText)
                        .textFieldStyle(.roundedBorder)
                }
            }
            .disabled(model.isSaving)

            if model.invalidCap {
                Text(TaskPageCopy.invalidSpendingLimit.text)
                    .foregroundStyle(Tokens.Tone.stop.foreground)
            }
            if let failure = model.failure {
                Text(verbatim: failure.text)
                    .foregroundStyle(Tokens.Tone.stop.foreground)
            }

            HStack(spacing: 10) {
                Spacer()
                if model.isSaving { ProgressView().controlSize(.small) }
                Button(AddTaskCopy.cancel.text, action: dismiss)
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.isSaving)
                Button(AddTaskCopy.saveChanges.text) {
                    Task {
                        if await model.save() { dismiss() }
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canSave)
            }
        }
        .padding(Tokens.Spacing.sheet)
        .frame(width: 420)
        .background(Tokens.Palette.sheet)
        .interactiveDismissDisabled(model.isSaving)
    }
}
