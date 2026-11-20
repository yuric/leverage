import LeverageKit
import SwiftUI

/// The Add task sheet (MA-13). Built with no arguments; the shell presents it
/// and puts its `ScreenContext` in the environment. After a save it calls
/// `finishAddTask()`, which closes the sheet and shows the board.
struct AddTaskSheet: View {
    @Environment(ScreenContext.self) private var context
    @State private var box = ScreenModelBox<AddTaskModel>()

    var body: some View {
        let navigator = context.navigator
        let model = box.model {
            AddTaskModel(api: context.owner, onSaved: { navigator.finishAddTask() })
        }
        AddTaskForm(model: model, cancel: { navigator.isAddTaskPresented = false })
    }
}

/// A text area that shows a placeholder while it is empty.
struct PlaceholderEditor: View {
    @Binding var text: String
    let placeholder: String
    var minHeight: CGFloat = 64

    var body: some View {
        TextEditor(text: $text)
            .font(.system(size: Tokens.FontSize.body))
            .scrollContentBackground(.hidden)
            .padding(4)
            .frame(minHeight: minHeight)
            .background(
                Tokens.Palette.control, in: RoundedRectangle(cornerRadius: Tokens.Radius.control, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Tokens.Radius.control, style: .continuous)
                    .strokeBorder(Tokens.Palette.line, lineWidth: 1)
            )
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(verbatim: placeholder)
                        .font(.system(size: Tokens.FontSize.body))
                        .foregroundStyle(Tokens.Palette.placeholder)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 12)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
    }
}

/// One labelled field of a form.
struct FormField<Content: View>: View {
    let label: String
    var hint: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: label)
                .font(.system(size: Tokens.FontSize.small, weight: .semibold))
                .foregroundStyle(Tokens.Palette.text2)
            content
            if let hint {
                Text(verbatim: hint)
                    .font(.system(size: Tokens.FontSize.small))
                    .foregroundStyle(Tokens.Palette.text2)
            }
        }
    }
}

/// The form itself, drawn from its model.
struct AddTaskForm: View {
    @Bindable var model: AddTaskModel
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(AddTaskCopy.sheetTitle.text)
                .font(.system(size: 20, weight: .semibold))
                .padding(.bottom, 14)
            ScrollView {
                AddTaskFields(model: model)
                    .padding(.trailing, 6)
            }
            Text(AddTaskCopy.footnote.text)
                .font(.system(size: Tokens.FontSize.small))
                .foregroundStyle(Tokens.Palette.text2)
                .padding(.top, 12)
            if model.ideaDropsCriteria {
                Text(AddTaskCopy.ideaKeepsNoCriteria.text)
                    .font(.system(size: Tokens.FontSize.small))
                    .foregroundStyle(Tokens.Palette.text2)
                    .padding(.top, 4)
            }
            if let failure = model.failure {
                VStack(alignment: .leading, spacing: 4) {
                    if model.savedWithoutContract {
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
                Button(AddTaskCopy.saveAsIdea.text) {
                    Task { await model.saveAsIdea() }
                }
                .disabled(!model.canSaveAsIdea)
                Button(AddTaskCopy.save.text) {
                    Task { await model.save() }
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

/// The fields of the form, one under another.
struct AddTaskFields: View {
    @Bindable var model: AddTaskModel
    @FocusState private var titleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
                FormField(label: AddTaskCopy.titleLabel.text) {
                    TextField(AddTaskCopy.titlePlaceholder.text, text: $model.title)
                        .textFieldStyle(.roundedBorder)
                        .focused($titleFocused)
                }
                FormField(label: AddTaskCopy.goalLabel.text, hint: AddTaskCopy.goalHint.text) {
                    TextField(AddTaskCopy.goalPlaceholder.text, text: $model.goal)
                        .textFieldStyle(.roundedBorder)
                }
                FormField(label: AddTaskCopy.criteriaLabel.text, hint: AddTaskCopy.criteriaHint.text) {
                    PlaceholderEditor(text: $model.criteriaText, placeholder: AddTaskCopy.criteriaPlaceholder.text)
                }
                FormField(label: AddTaskCopy.detailsLabel.text) {
                    PlaceholderEditor(
                        text: $model.details, placeholder: AddTaskCopy.detailsPlaceholder.text, minHeight: 48)
                }
                FormField(label: AddTaskCopy.priorityLabel.text) {
                    Picker(AddTaskCopy.priorityLabel.text, selection: $model.priority) {
                        Text(AddTaskCopy.priorityLow.text).tag(Priority.low)
                        Text(AddTaskCopy.priorityNormal.text).tag(Priority.normal)
                        Text(AddTaskCopy.priorityHigh.text).tag(Priority.high)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                FormField(label: AddTaskCopy.workLabel.text, hint: AddTaskCopy.workHint.text) {
                    TextField(AddTaskCopy.workPlaceholder.text, text: $model.workReference)
                        .textFieldStyle(.roundedBorder)
                }
        }
        .onAppear { titleFocused = true }
    }
}
