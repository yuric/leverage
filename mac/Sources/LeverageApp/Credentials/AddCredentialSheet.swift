import LeverageKit
import SwiftUI

/// The Add credential pop-up (MA-17). Built by the Credentials screen, which
/// gives it the way to close itself; the shell's `ScreenContext` is in the
/// environment. `finish` runs when the login was added and when the owner
/// cancels.
struct AddCredentialSheet: View {
    let finish: @MainActor () -> Void
    @Environment(ScreenContext.self) private var context
    @State private var box = ScreenModelBox<AddCredentialModel>()

    var body: some View {
        let model = box.model {
            AddCredentialModel(api: context.owner, onAdded: finish)
        }
        AddCredentialForm(
            model: model,
            cancel: {
                model.cancel()
                finish()
            }
        )
        .task { await model.load() }
        .onDisappear { model.cancel() }
    }
}

/// The pop-up itself, drawn from its model.
struct AddCredentialForm: View {
    @Bindable var model: AddCredentialModel
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(CredentialsCopy.sheetTitle.text)
                .font(.system(size: 20, weight: .semibold))
            switch model.step {
            case .pickProvider: pickStep
            case .nameIt: nameStep
            case .checking, .done: checkStep
            }
            Spacer(minLength: 0)
            actions
        }
        .padding(Tokens.Spacing.sheet)
        .frame(width: 440, height: 520)
        .background(Tokens.Palette.sheet)
    }

    // MARK: step 1

    private var pickStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            label(CredentialsCopy.stepPick.text)
            ForEach(model.providers) { choice in
                Button {
                    model.pick(choice.provider)
                } label: {
                    HStack {
                        Text(verbatim: choice.name)
                        Spacer(minLength: 0)
                        if choice.isAdded {
                            Text(CredentialsCopy.added.text)
                                .foregroundStyle(Tokens.Palette.text2)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 28)
                }
                .disabled(choice.isAdded)
            }
            if let line = model.failure {
                problem(line)
            }
        }
    }

    // MARK: step 2

    private var nameStep: some View {
        let provider = model.provider.map(ProviderNames.name) ?? ""
        return VStack(alignment: .leading, spacing: 8) {
            label(CredentialsCopy.stepName.text)
            FormField(
                label: CredentialsCopy.nameLabel.filled(["provider": provider]),
                hint: CredentialsCopy.nameHint.filled(["provider": provider])
            ) {
                TextField(CredentialsCopy.namePlaceholder.text, text: $model.name)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await model.signIn() } }
            }
            if let line = model.nameLine {
                problem(line)
            }
        }
    }

    // MARK: the checks

    private var checkStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(model.checks) { line in
                HStack(spacing: 8) {
                    CheckMark(state: line.state)
                    Text(verbatim: line.text)
                        .font(.system(size: Tokens.FontSize.body))
                }
                .accessibilityElement(children: .combine)
                .accessibilityValue(Text(verbatim: stateWord(line.state)))
            }
            if let note = model.signInNote {
                aside(note)
            }
            if let ask = model.installAsk {
                VStack(alignment: .leading, spacing: 8) {
                    aside(ask.text)
                    if ask.canInstall {
                        if let installing = model.installNote {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text(verbatim: installing)
                                    .font(.system(size: Tokens.FontSize.small))
                                    .foregroundStyle(Tokens.Palette.text2)
                            }
                        } else {
                            Button(CredentialsCopy.installButton.text) {
                                Task { await model.install() }
                            }
                        }
                    }
                    if let line = model.installFailure {
                        problem(line)
                    }
                }
            }
            if let line = model.failure {
                problem(line)
            }
        }
    }

    // MARK: buttons

    private var actions: some View {
        HStack(spacing: 10) {
            if model.step == .nameIt {
                Button(CredentialsCopy.back.text) { model.back() }
            }
            Spacer(minLength: 0)
            Button(CredentialsCopy.cancel.text, action: cancel)
                .keyboardShortcut(.cancelAction)
            switch model.step {
            case .nameIt:
                Button(CredentialsCopy.signIn.text) { Task { await model.signIn() } }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canSignIn)
            case .checking where model.canRetry:
                Button(CredentialsCopy.retry.text) { Task { await model.retry() } }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            case .pickProvider, .checking, .done:
                EmptyView()
            }
        }
    }

    // MARK: small parts

    private func label(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.system(size: Tokens.FontSize.small, weight: .semibold))
            .foregroundStyle(Tokens.Palette.text2)
    }

    private func aside(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.system(size: Tokens.FontSize.small))
            .foregroundStyle(Tokens.Palette.text2)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Tokens.Palette.inset, in: RoundedRectangle(cornerRadius: Tokens.Radius.control, style: .continuous))
    }

    private func problem(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.system(size: Tokens.FontSize.body, weight: .medium))
            .foregroundStyle(Tokens.Tone.stop.foreground)
    }

    private func stateWord(_ state: HelperCheckState) -> String {
        switch state {
        case .waiting: CredentialsCopy.stateWaiting.text
        case .running, .waitingForSignIn, .waitingForInstall: CredentialsCopy.stateWorking.text
        case .passed: CredentialsCopy.statePassed.text
        case .failed: CredentialsCopy.stateFailed.text
        }
    }
}

/// A tick, a spinner, a cross or an empty circle for one check.
struct CheckMark: View {
    let state: HelperCheckState

    var body: some View {
        Group {
            switch state {
            case .passed:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Tokens.Palette.ok)
            case .failed:
                Image(systemName: "xmark.circle.fill").foregroundStyle(Tokens.Tone.stop.foreground)
            case .running, .waitingForSignIn, .waitingForInstall:
                ProgressView().controlSize(.small)
            case .waiting:
                Image(systemName: "circle").foregroundStyle(Tokens.Palette.field)
            }
        }
        .frame(width: 18, height: 18)
        .accessibilityHidden(true)
    }
}
