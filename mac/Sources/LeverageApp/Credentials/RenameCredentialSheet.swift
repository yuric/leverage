import SwiftUI

struct RenameCredentialSheet: View {
    let model: CredentialsModel
    let id: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var failure: String?
    @State private var isSaving = false

    init(model: CredentialsModel, row: CredentialRow) {
        self.model = model
        id = row.id
        _name = State(initialValue: row.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(CredentialsCopy.rename.text)
                .font(.system(size: Tokens.FontSize.head, weight: .semibold))
            VStack(alignment: .leading, spacing: 4) {
                TextField(CredentialsCopy.renameField.text, text: $name)
                    .disabled(isSaving)
                    .onChange(of: name) { failure = nil }
                if let failure {
                    Text(verbatim: failure)
                        .font(.system(size: Tokens.FontSize.small))
                        .foregroundStyle(Tokens.Tone.stop.foreground)
                }
            }
            HStack {
                Spacer()
                Button(CredentialsCopy.cancel.text) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSaving)
                Button((isSaving ? CredentialsCopy.renaming : .rename).text) {
                    isSaving = true
                    Task {
                        let error = await model.rename(id, to: name)
                        isSaving = false
                        if let error { failure = error } else { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isSaving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
        .interactiveDismissDisabled(isSaving)
    }
}
