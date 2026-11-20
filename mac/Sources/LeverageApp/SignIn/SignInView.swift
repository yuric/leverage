import SwiftUI

/// Create the sign-in on a new installation, or sign in (IN-2, MA-5).
struct SignInView: View {
    @Bindable var model: SignInModel
    @FocusState private var focus: Field?

    private enum Field { case email, password }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                AppIconView(size: 32)
                Text(title.text)
                    .font(.system(size: 20, weight: .semibold))
            }
            Text(body_.text)
                .font(.system(size: Tokens.FontSize.body))
                .foregroundStyle(Tokens.Palette.text2)

            VStack(alignment: .leading, spacing: 12) {
                field(SignInCopy.emailLabel) {
                    TextField(SignInCopy.emailPlaceholder.text, text: $model.email)
                        .textContentType(.username)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .email)
                        .onSubmit { focus = .password }
                }
                field(SignInCopy.passwordLabel) {
                    SecureField(SignInCopy.passwordLabel.text, text: $model.password)
                        .textContentType(model.mode == .create ? .newPassword : .password)
                        .focused($focus, equals: .password)
                        .onSubmit { submit() }
                }
                if model.mode == .create {
                    Text(SignInCopy.passwordHintCreate.text)
                        .font(.system(size: Tokens.FontSize.small))
                        .foregroundStyle(Tokens.Palette.text2)
                }
            }

            if let failure = model.failure {
                Text(failure.text)
                    .font(.system(size: Tokens.FontSize.body, weight: .medium))
                    .foregroundStyle(Tokens.Tone.stop.foreground)
                    .accessibilityAddTraits(.isStaticText)
            }

            HStack(spacing: 10) {
                Button(buttonCopy.text) { submit() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!model.canSubmit)
                    .keyboardShortcut(.defaultAction)
                if model.isBusy {
                    ProgressView().controlSize(.small)
                    Text(SignInCopy.busy.text)
                        .font(.system(size: Tokens.FontSize.small))
                        .foregroundStyle(Tokens.Palette.text2)
                }
            }
        }
        .padding(Tokens.Spacing.sheet)
        .frame(width: 400)
        .background(
            Tokens.Palette.sheet, in: RoundedRectangle(cornerRadius: Tokens.Radius.window, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.Radius.window, style: .continuous)
                .strokeBorder(Tokens.Palette.line, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.2), radius: 24, y: 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { focus = .email }
    }

    private func submit() {
        Task { await model.submit() }
    }

    private var title: SignInCopy { model.mode == .create ? .createTitle : .signInTitle }
    private var body_: SignInCopy { model.mode == .create ? .createBody : .signInBody }
    private var buttonCopy: SignInCopy { model.mode == .create ? .createButton : .signInButton }

    private func field<Content: View>(_ label: SignInCopy, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.text)
                .font(.system(size: Tokens.FontSize.small, weight: .semibold))
                .foregroundStyle(Tokens.Palette.text2)
            content()
                .textFieldStyle(.roundedBorder)
        }
    }
}
