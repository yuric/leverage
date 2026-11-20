import SwiftUI

/// The Credentials tab (MA-8): a flat list of logins with Add credential and
/// Verify per row, and Sign in again on a signed-out one (HM-47). Built with no arguments; the shell puts its
/// `ScreenContext` in the environment. It draws its own Add credential
/// sheet.
struct CredentialsView: View {
    @Environment(ScreenContext.self) private var context
    @State private var box = ScreenModelBox<CredentialsModel>()
    @State private var isAdding = false

    var body: some View {
        let model = box.model {
            CredentialsModel(api: context.owner, noteRead: { [feed = context.feed] in feed.noteRead(asOfSeq: $0) })
        }
        CredentialsContent(model: model, add: { isAdding = true })
            .task {
                model.attach(to: context.feed)
                await model.load()
            }
            .onDisappear { model.detach() }
            .sheet(isPresented: $isAdding) {
                AddCredentialSheet(finish: {
                    isAdding = false
                    Task { await model.load() }
                })
                .environment(context)
            }
    }
}

/// What the screen draws from its model.
struct CredentialsContent: View {
    let model: CredentialsModel
    let add: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(CredentialsCopy.header.text)
                    .font(.system(size: Tokens.FontSize.body))
                    .foregroundStyle(Tokens.Palette.text2)
                Spacer(minLength: 0)
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
            if model.state == .loaded, model.rows.isEmpty {
                note(CredentialsCopy.empty.text)
            }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(model.rows) { row in
                        CredentialRowView(row: row, model: model)
                    }
                }
            }
        }
    }

    private func note(_ text: String, tone: Color = Tokens.Palette.text2) -> some View {
        Text(verbatim: text)
            .font(.system(size: Tokens.FontSize.body, weight: .medium))
            .foregroundStyle(tone)
    }
}

/// One login: its name and kind, its chip and what it can do, Verify, and
/// Sign in again on a signed-out one (HM-47).
struct CredentialRowView: View {
    let row: CredentialRow
    let model: CredentialsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: row.name)
                    .font(.system(size: Tokens.FontSize.body, weight: .semibold))
                Text(verbatim: "\(row.providerName) · \(row.kindLine)")
                    .font(.system(size: Tokens.FontSize.small))
                    .foregroundStyle(Tokens.Palette.text2)
                Spacer(minLength: 0)
                if model.isVerifying(row.id) {
                    ProgressView().controlSize(.small)
                    Text(CredentialsCopy.verifying.text)
                        .font(.system(size: Tokens.FontSize.small))
                        .foregroundStyle(Tokens.Palette.text2)
                } else if model.isSigningIn(row.id) {
                    ProgressView().controlSize(.small)
                } else {
                    if row.canSignInAgain {
                        Button(CredentialsCopy.signInAgain.text) {
                            Task { await model.signInAgain(row.id) }
                        }
                    }
                    Button(CredentialsCopy.verify.text) {
                        Task { await model.verify(row.id) }
                    }
                }
            }
            HStack(spacing: 8) {
                Chip(text: row.chip.text, tone: row.chip.tone)
                Text(verbatim: row.usage)
                    .font(.system(size: Tokens.FontSize.small))
                    .foregroundStyle(Tokens.Palette.text2)
            }
            if let waiting = model.signInWaitingLine(row.id) {
                Text(verbatim: waiting)
                    .font(.system(size: Tokens.FontSize.small))
                    .foregroundStyle(Tokens.Palette.text2)
            }
            if let line = model.failure(for: row.id) {
                Text(verbatim: line)
                    .font(.system(size: Tokens.FontSize.small, weight: .medium))
                    .foregroundStyle(Tokens.Tone.stop.foreground)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.Palette.surface, in: RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                .strokeBorder(Tokens.Palette.line, lineWidth: 1))
        .accessibilityElement(children: .contain)
    }
}
