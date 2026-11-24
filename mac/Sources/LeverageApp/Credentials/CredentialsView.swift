import SwiftUI

/// The Credentials tab. The shell puts its ScreenContext in the environment.
struct CredentialsView: View {
    @Environment(ScreenContext.self) private var context
    @State private var box = ScreenModelBox<CredentialsModel>()

    var body: some View {
        @Bindable var navigator = context.navigator
        let model = box.model {
            CredentialsModel(
                api: context.owner, noteRead: { [feed = context.feed] in feed.noteRead(asOfSeq: $0) },
                helper: context.runtime.helper)
        }
        CredentialsContent(model: model, add: { navigator.presentAddCredential() })
            .task {
                model.attach(to: context.feed)
                await model.keepCurrent()
            }
            .onDisappear { model.detach() }
            .sheet(isPresented: $navigator.isAddCredentialPresented) {
                AddCredentialSheet(finish: {
                    navigator.isAddCredentialPresented = false
                    Task { await model.load() }
                })
                .environment(context)
            }
    }
}

struct CredentialsContent: View {
    let model: CredentialsModel
    let add: () -> Void
    @State private var renaming: CredentialRow?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                note(CredentialsCopy.header.text)
                Spacer(minLength: 0)
                Button(CredentialsCopy.refresh.text) { Task { await model.refresh() } }
                    .disabled(model.isRunningBatch)
                Button(CredentialsCopy.verifyAll.text) { Task { await model.verifyAll() } }
                    .disabled(!model.canVerifyAll)
                Button(CredentialsCopy.addCredential.text, action: add)
                    .buttonStyle(PrimaryButtonStyle())
            }
            switch model.state {
            case .loading:
                note(CredentialsCopy.loading.text)
            case .signedOut:
                note(ShellCopy.transportUnauthenticated.text, tone: Tokens.Tone.stop.foreground)
            case .failed(let copy):
                note(copy.text, tone: Tokens.Tone.stop.foreground)
            case .loaded:
                EmptyView()
            }
            if let failure = model.actionFailure {
                note(failure, tone: Tokens.Tone.stop.foreground)
            }
            if model.state == .loaded || !model.rows.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(model.sections, id: \.kind) { section in
                            credentialSection(section)
                        }
                    }
                }
            }
        }
        .sheet(item: $renaming) { row in
            RenameCredentialSheet(model: model, row: row)
        }
        .confirmationDialog(
            model.pendingRemoval.map { CredentialsCopy.removeTitle.filled(["name": $0.name]) } ?? "",
            isPresented: removing, titleVisibility: .visible, presenting: model.pendingRemoval
        ) { row in
            Button(CredentialsCopy.remove.text, role: .destructive) {
                Task { await model.remove(row.id) }
            }
            Button(CredentialsCopy.cancel.text, role: .cancel) { model.cancelRemoval() }
        } message: { _ in
            Text(CredentialsCopy.removeMessage.text)
        }
    }

    private var removing: Binding<Bool> {
        Binding(get: { model.pendingRemoval != nil }, set: { if !$0 { model.cancelRemoval() } })
    }

    private func credentialSection(_ section: CredentialsModel.Section) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text((section.kind == .login ? AddTokenCopy.loginProviders : .tokenProviders).text)
                .font(.system(size: Tokens.FontSize.body, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            if section.groups.isEmpty {
                note((section.kind == .login ? CredentialsCopy.empty : .noTokens).text)
            }
            ForEach(section.groups, id: \.provider) { group in
                VStack(alignment: .leading, spacing: 8) {
                    Text(verbatim: ProviderNames.name(group.provider))
                        .font(.system(size: Tokens.FontSize.small, weight: .semibold))
                        .foregroundStyle(Tokens.Palette.text2)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(group.rows) { row in
                        CredentialRowView(row: row, model: model, rename: { renaming = row })
                    }
                }
            }
        }
    }

    private func note(_ text: String, tone: Color = Tokens.Palette.text2) -> some View {
        Text(verbatim: text)
            .font(.system(size: Tokens.FontSize.body))
            .foregroundStyle(tone)
    }
}
