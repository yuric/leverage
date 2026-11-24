import LeverageKit
import SwiftUI

/// The first and the second login: the logins added so far, four provider
/// tiles, the name field and Sign in, then the same three checks as Add
/// credential. The second screen also lets the owner go on with one.
struct SetupLoginScreen: View {
    let model: SetupAssistantModel

    private var isSecond: Bool { model.screen == .secondLogin }

    var body: some View {
        AssistantScreen {
            if isSecond {
                AssistantHeading(.secondLoginTitle, .secondLoginBody)
            } else {
                AssistantHeading(.firstLoginTitle, .firstLoginBody)
            }
            if !model.facts.logins.isEmpty {
                AssistantList(items: model.facts.logins, label: SetupAssistantCopy.loginsAdded.text) { login in
                    AddedLoginRow(login: login)
                }
            }
            if model.showsTiles {
                if let attempt = model.attempt, attempt.step == .checking || attempt.step == .done {
                    SignInChecks(model: model, attempt: attempt)
                } else {
                    ProviderTiles(model: model)
                    if let attempt = model.attempt, attempt.step == .nameIt {
                        SignInForm(model: model, attempt: attempt)
                    }
                    if isSecond {
                        oneSubscription
                    }
                }
            } else if !isSecond {
                AssistantMuted(text: SetupAssistantCopy.nextLogin.text)
            }
        } footer: {
            AssistantBackButton(model: model)
            Spacer(minLength: 0)
            AssistantPrimaryButton(title: SetupAssistantCopy.continueButton.text, enabled: model.canContinue) {
                model.next()
            }
        }
    }

    @ViewBuilder
    private var oneSubscription: some View {
        Button(SetupAssistantCopy.oneSubscription.text) { model.toggleOneSubscription() }
            .buttonStyle(AssistantLinkStyle(quiet: true))
        if model.showsOneSubscription {
            AssistantNote(text: SetupAssistantCopy.oneSubscriptionNote.text, wait: true) {
                Button(SetupAssistantCopy.continueWithOne.text) { model.continueWithOne() }
                    .buttonStyle(AssistantButtonStyle())
            }
        }
    }
}

/// "Claude, Personal", a subscription login that answered its checks.
private struct AddedLoginRow: View {
    let login: SetupModel.Login

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: login.label)
                    .font(.system(size: Tokens.FontSize.body, weight: .semibold))
                AssistantMuted(text: SetupAssistantCopy.loginRowLine.text)
            }
            Spacer(minLength: 0)
            Chip(text: CredentialsCopy.added.text, tone: .done)
        }
        .padding(.vertical, 12)
        .padding(.leading, 16)
        .padding(.trailing, 14)
        .accessibilityElement(children: .combine)
    }
}

/// The four providers a login can be added for.
private struct ProviderTiles: View {
    let model: SetupAssistantModel

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(model.tiles) { tile in
                ProviderTileButton(tile: tile, selected: model.attempt?.provider == tile.provider) {
                    model.pick(tile.provider)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(SetupAssistantCopy.providersLabel.text))
    }
}

private struct ProviderTileButton: View {
    let tile: SetupAssistantModel.ProviderTile
    let selected: Bool
    let action: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: String(tile.name.prefix(1)))
                    .font(.system(size: Tokens.FontSize.body, weight: .bold))
                    .frame(width: 28, height: 28)
                    .background(Tokens.Palette.inset, in: RoundedRectangle(cornerRadius: Tokens.Radius.control))
                    .padding(.bottom, 4)
                    .accessibilityHidden(true)
                Text(verbatim: tile.name)
                    .font(.system(size: Tokens.FontSize.body, weight: .semibold))
                Text(tile.isAdded ? SetupAssistantCopy.alreadyAdded.text
                    : SetupAssistantCopy.runsIn.filled(["tool": tile.tool]))
                    .font(.system(size: Tokens.FontSize.badge))
                    .foregroundStyle(Tokens.Palette.text2)
                if let note = tile.note, !tile.isAdded {
                    Text(note)
                        .font(.system(size: Tokens.FontSize.badge, weight: .semibold))
                        .foregroundStyle(Tokens.Tone.wait.foreground)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, minHeight: 84, maxHeight: .infinity, alignment: .topLeading)
            .padding(10)
            .foregroundStyle(Tokens.Palette.text)
            .background(Tokens.Palette.surface, in: shape)
            .overlay(shape.strokeBorder(selected ? Tokens.Palette.primary : Tokens.Palette.line, lineWidth: selected ? 2 : 1))
            .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(tile.isAdded)
        .opacity(tile.isAdded ? 0.38 : 1)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The name for the login, and Sign in.
private struct SignInForm: View {
    let model: SetupAssistantModel
    @Bindable var attempt: AddCredentialModel
    @FocusState private var focused: Bool

    var body: some View {
        let provider = attempt.selection?.name ?? ""
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .bottom, spacing: 8) {
                FormField(label: CredentialsCopy.nameLabel.filled(["provider": provider])) {
                    TextField(CredentialsCopy.namePlaceholder.text, text: $attempt.name)
                        .textFieldStyle(.roundedBorder)
                        .focused($focused)
                        .onSubmit { Task { await model.signIn() } }
                }
                Button(CredentialsCopy.signIn.text) { Task { await model.signIn() } }
                    .buttonStyle(AssistantTintStyle())
                    .disabled(!attempt.canSignIn)
            }
            if let line = attempt.nameLine {
                AssistantProblem(text: line)
            }
            AssistantMuted(text: CredentialsCopy.nameHint.filled(["provider": provider]))
        }
        .assistantCard(padding: 14)
        .onAppear { focused = true }
    }
}

/// The three checks as the helper reports them, and what each one waits for.
private struct SignInChecks: View {
    let model: SetupAssistantModel
    let attempt: AddCredentialModel

    var body: some View {
        let login = "\(attempt.selection?.name ?? ""), \(attempt.name.trimmingCharacters(in: .whitespacesAndNewlines))"
        VStack(alignment: .leading, spacing: 10) {
            Text(SetupAssistantCopy.checking.filled(["login": login]))
                .font(.system(size: Tokens.FontSize.small, weight: .semibold))
                .foregroundStyle(Tokens.Palette.text2)
            AssistantList(items: attempt.checks, label: SetupAssistantCopy.checking.filled(["login": login])) { line in
                HStack(alignment: .top, spacing: 10) {
                    CheckMark(state: line.state)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(line.text)
                            .font(.system(size: Tokens.FontSize.body))
                        if line.check == .signedIn, let note = attempt.signInNote {
                            AssistantMuted(text: note)
                        }
                    }
                    Spacer(minLength: 0)
                    Text(stateWord(line.state))
                        .font(.system(size: Tokens.FontSize.small, weight: .semibold))
                        .foregroundStyle(Tokens.Palette.text2)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .accessibilityElement(children: .combine)
            }
            if let ask = attempt.installAsk {
                AssistantNote(text: ask.text) {
                    if ask.canInstall {
                        if let installing = attempt.installNote {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text(installing)
                            }
                        } else {
                            Button(CredentialsCopy.installButton.text) { Task { await model.install() } }
                                .buttonStyle(AssistantTintStyle())
                        }
                    }
                }
                if let line = attempt.installFailure {
                    AssistantProblem(text: line)
                }
            }
            if let line = attempt.failure {
                AssistantProblem(text: line)
            }
            HStack(spacing: 8) {
                if attempt.canRetry {
                    Button(CredentialsCopy.retry.text) { Task { await model.retry() } }
                        .buttonStyle(AssistantTintStyle())
                }
                if attempt.step != .done {
                    Button(CredentialsCopy.cancel.text) { model.cancelSignIn() }
                        .buttonStyle(AssistantButtonStyle())
                }
            }
        }
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
