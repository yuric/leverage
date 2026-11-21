import SwiftUI

struct WorkspaceSettingsView: View {
    @Environment(ScreenContext.self) private var context
    @State private var box = ScreenModelBox<WorkspaceSettingsModel>()

    var body: some View {
        let model = box.model { WorkspaceSettingsModel(api: context.owner) }
        WorkspaceSettingsContent(model: model)
            .task {
                model.attach(to: context.feed)
                await model.load()
            }
            .onDisappear { model.detach() }
    }
}

struct WorkspaceSettingsContent: View {
    let model: WorkspaceSettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(WorkspaceSettingsCopy.title.text)
                .font(.system(size: 17, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            status
            if model.hasLoaded, model.state != .signedOut {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(WorkspaceSettingsModel.Field.allCases, id: \.self) { field in
                            let label = WorkspaceSettingsCopy.label(for: field).text
                            let hint = WorkspaceSettingsCopy.hint(for: field)
                            FormField(label: label, hint: hint) {
                                TextField(label, text: Binding(
                                    get: { model.fields[field, default: ""] },
                                    set: { model.fields[field] = $0 }))
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 112)
                                    .accessibilityHint(hint)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .disabled(model.isSaving)
                }
                Button((model.isSaving ? WorkspaceSettingsCopy.saving : .save).text) {
                    Task { await model.save() }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!model.canSave)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var status: some View {
        switch model.state {
        case .loading:
            Text(WorkspaceSettingsCopy.loading.text)
                .foregroundStyle(Tokens.Palette.text2)
        case .failed(let copy):
            Text(copy.text)
                .foregroundStyle(Tokens.Tone.stop.foreground)
            if !model.hasLoaded {
                Button(WorkspaceSettingsCopy.retry.text) { Task { await model.load() } }
            }
        case .signedOut:
            Text(ShellCopy.transportUnauthenticated.text)
                .foregroundStyle(Tokens.Tone.stop.foreground)
        case .loaded:
            EmptyView()
        }
    }
}
