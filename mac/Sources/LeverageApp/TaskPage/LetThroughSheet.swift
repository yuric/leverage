import SwiftUI

/// The sheet that asks the owner why a check is let through once (RD-29,
/// RD-48). Presented by the task page while `TaskPageModel.letThrough` is set.
struct LetThroughSheet: View {
    @Bindable var model: LetThroughModel
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(TaskPageCopy.letThroughTitle.filled(["rule": model.ruleName]))
                .font(.system(size: 20, weight: .semibold))
            Text(TaskPageCopy.letThroughExplain.text)
                .font(.system(size: Tokens.FontSize.body))
                .foregroundStyle(Tokens.Palette.text2)
            FormField(label: TaskPageCopy.letThroughReasonLabel.text) {
                PlaceholderEditor(
                    text: $model.reason, placeholder: TaskPageCopy.letThroughReasonPlaceholder.text, minHeight: 72)
            }
            if let failure = model.failure {
                Text(verbatim: failure.text)
                    .font(.system(size: Tokens.FontSize.body, weight: .medium))
                    .foregroundStyle(Tokens.Tone.stop.foreground)
            }
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                if model.isBusy {
                    ProgressView().controlSize(.small)
                    Text(TaskPageCopy.letThroughSending.text)
                        .font(.system(size: Tokens.FontSize.small))
                        .foregroundStyle(Tokens.Palette.text2)
                }
                Button(TaskPageCopy.letThroughCancel.text, action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button(TaskPageCopy.letThroughConfirm.text) { Task { await model.send() } }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canSend)
            }
            .padding(.top, 4)
        }
        .padding(Tokens.Spacing.sheet)
        .frame(width: 440)
        .background(Tokens.Palette.sheet)
    }
}
