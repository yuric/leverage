import LeverageKit
import SwiftUI

struct ImaginariumView: View {
    @Environment(ScreenContext.self) private var context
    @State private var catalog = try? ImaginariumCatalog.launch()
    @State private var search = ""
    @State private var category: String?
    @State private var selected: ImaginariumCatalog.Entry?
    @State private var copiedEntryID: String?

    var body: some View {
        if let catalog {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    hero(catalog)
                    filters(catalog)
                    tiles(catalog)
                }
                .padding(.bottom, 12)
            }
            .sheet(item: $selected) { entry in
                ImaginariumTrySheet(entry: entry, catalogVersion: catalog.version, api: context.owner)
                    .environment(context)
            }
        } else {
            ContentUnavailableView(ImaginariumCopy.catalogUnavailable.text, systemImage: "sparkles")
        }
    }

    private func hero(_ catalog: ImaginariumCatalog) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(ImaginariumCopy.headline.text)
                .font(.system(size: 34, weight: .bold))
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: 12) {
                TextField(ImaginariumCopy.searchPrompts.text, text: $search)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(ImaginariumCopy.searchPrompts.text)
                Button {
                    selected = catalog.entries.randomElement()
                } label: {
                    Label(ImaginariumCopy.surpriseMe.text, systemImage: "shuffle")
                }
                .buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.Palette.imaginariumTint, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Tokens.Palette.imaginariumOutline, lineWidth: 1))
    }

    private func filters(_ catalog: ImaginariumCatalog) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                filter(ImaginariumCopy.all.text, value: nil)
                ForEach(catalog.categories) { item in
                    filter(item.name, value: item.id)
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private func filter(_ title: String, value: String?) -> some View {
        Button {
            category = value
        } label: {
            Text(verbatim: title)
                .font(.system(size: Tokens.FontSize.body, weight: category == value ? .semibold : .medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(category == value ? Tokens.Palette.tabOnBackground : Tokens.Palette.inset, in: Capsule())
                .overlay(Capsule().strokeBorder(category == value ? Tokens.Palette.focus : Tokens.Palette.line))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(category == value ? .isSelected : [])
    }

    @ViewBuilder
    private func tiles(_ catalog: ImaginariumCatalog) -> some View {
        let filtered = catalog.filteredEntries(category: category, search: search)
        if filtered.isEmpty {
            ContentUnavailableView(ImaginariumCopy.noMatchingPrompts.text, systemImage: "magnifyingglass")
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 14, alignment: .top)], spacing: 14) {
                ForEach(filtered) { entry in
                    tile(entry, categoryName: catalog.categories.first { $0.id == entry.category }?.name ?? entry.category)
                }
            }
        }
    }

    private func tile(_ entry: ImaginariumCatalog.Entry, categoryName: String) -> some View {
        let copied = copiedEntryID == entry.id
        return VStack(alignment: .leading, spacing: 0) {
            ImaginariumArt(category: entry.category)
                .frame(height: 108)
                .overlay(alignment: .topLeading) {
                    Chip(text: categoryName, tone: .plain).padding(10)
                }
                .overlay(alignment: .topTrailing) {
                    Chip(text: ImaginariumCopy.estimate(entry.minutes), tone: .plain).padding(10)
                }
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: entry.title)
                    .font(.system(size: 17, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(verbatim: entry.description)
                    .font(.system(size: Tokens.FontSize.body))
                    .foregroundStyle(Tokens.Palette.text2)
                    .fixedSize(horizontal: false, vertical: true)
                if entry.needs.contains(.imageTool) {
                    Label(ImaginariumCopy.needsImageTool.text, systemImage: "photo")
                        .font(.system(size: Tokens.FontSize.small))
                        .foregroundStyle(Tokens.Tone.wait.foreground)
                }
                HStack(spacing: 8) {
                    Button(ImaginariumCopy.tryIt.text) { selected = entry }
                        .buttonStyle(PrimaryButtonStyle())
                        .accessibilityLabel(ImaginariumCopy.tryPrompt.filled(["title": entry.title]))
                    Button {
                        Pasteboard.copy(entry.filledPrompt())
                        copiedEntryID = entry.id
                    } label: {
                        Image(systemName: copied ? "checkmark" : "document.on.document")
                    }
                    .help(copied ? ImaginariumCopy.copied.text : ImaginariumCopy.copyPrompt.text)
                    .accessibilityLabel(
                        copied ? ImaginariumCopy.copied.text : ImaginariumCopy.copyNamedPrompt.filled(["title": entry.title])
                    )
                    if copied {
                        Text(ImaginariumCopy.copied.text).font(.system(size: Tokens.FontSize.small))
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Tokens.Palette.surface, in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
        .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.card).strokeBorder(Tokens.Palette.line))
    }
}

struct ImaginariumTrySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ScreenContext.self) private var context
    @State private var model: ImaginariumTryModel
    @State private var copied = false

    init(entry: ImaginariumCatalog.Entry, catalogVersion: Int, api: any OwnerAPI) {
        _model = State(wrappedValue: ImaginariumTryModel(entry: entry, catalogVersion: catalogVersion, api: api))
    }

    private var project: Project? {
        context.paneProjects.first { $0.imaginarium && $0.contentDeletedAt == nil }
    }

    var body: some View {
        VStack(spacing: 0) {
            ImaginariumArt(category: model.entry.category)
                .frame(height: 108)
                .overlay(alignment: .topTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(ImaginariumCopy.close.text)
                    .keyboardShortcut(.cancelAction)
                    .padding(14)
                }
            ScrollView {
                if case let .saved(state, reason) = model.state {
                    confirmation(state, reason: reason)
                } else {
                    form
                }
            }
        }
        .frame(width: 720, height: 570)
        .background(Tokens.Palette.sheet)
        .task(id: model.isChecking) { await model.watchStatus() }
        .onChange(of: model.prompt) { _, _ in copied = false }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(ImaginariumCopy.estimate(model.entry.minutes))
                .font(.system(size: Tokens.FontSize.small, weight: .semibold))
                .foregroundStyle(Tokens.Palette.text2)
            Text(verbatim: model.entry.title)
                .font(.system(size: 28, weight: .bold))
                .accessibilityAddTraits(.isHeader)
            Text(verbatim: model.entry.description)
                .foregroundStyle(Tokens.Palette.text2)
            if model.entry.needs.contains(.imageTool) {
                Label(ImaginariumCopy.needsImageTool.text, systemImage: "photo")
                    .foregroundStyle(Tokens.Tone.wait.foreground)
            }
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(ImaginariumCopy.makeItYours.text).font(.headline)
                    ForEach(model.entry.fills, id: \.key) { fill in
                        ImaginariumFillField(label: fill.label, value: fillValue(fill))
                    }
                    Text(ImaginariumCopy.doneWhen.text).font(.headline)
                    ForEach(Array(model.criteria.enumerated()), id: \.offset) { _, criterion in
                        Label(criterion.text, systemImage: criterion.kind == .review ? "person.2" : "checkmark.circle")
                            .font(.system(size: Tokens.FontSize.body))
                    }
                }
                .frame(width: 230, alignment: .leading)
                .disabled(!model.canEdit)
                promptEditor
            }
            actions
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func fillValue(_ fill: ImaginariumCatalog.Fill) -> Binding<String> {
        Binding {
            model.fills[fill.key] ?? fill.defaultValue
        } set: {
            model.fills[fill.key] = $0
        }
    }

    private var promptEditor: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(ImaginariumCopy.prompt.text).font(.headline)
                Spacer()
                Button(model.isEditingPrompt ? ImaginariumCopy.doneEditing.text : ImaginariumCopy.editPrompt.text) {
                    model.isEditingPrompt.toggle()
                }
                .disabled(!model.canEdit)
            }
            Group {
                if model.isEditingPrompt {
                    TextEditor(text: $model.prompt)
                        .scrollContentBackground(.hidden)
                        .accessibilityLabel(ImaginariumCopy.prompt.text)
                        .disabled(!model.canEdit)
                } else {
                    ScrollView {
                        Text(verbatim: model.prompt)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .font(.system(.body, design: .monospaced))
            .padding(10)
            .frame(height: 176)
            .background(Tokens.Palette.inset, in: RoundedRectangle(cornerRadius: Tokens.Radius.control))
            if model.isEdited {
                Text(ImaginariumCopy.fillInsKeepEdits.text)
                    .font(.system(size: Tokens.FontSize.small))
                    .foregroundStyle(Tokens.Palette.text2)
                Button(ImaginariumCopy.undoEdits.text) { model.undoEdits() }
                    .buttonStyle(.link)
                    .disabled(!model.canEdit)
            }
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let project {
                Label(ImaginariumCopy.goesToProject.filled(["project": project.name]), systemImage: "folder")
            } else {
                Text(ImaginariumCopy.projectUnavailable.text)
                    .foregroundStyle(Tokens.Tone.wait.foreground)
            }
            HStack {
                Button(copied ? ImaginariumCopy.copied.text : ImaginariumCopy.copyPrompt.text) {
                    Pasteboard.copy(model.prompt)
                    copied = true
                }
                if let project, model.canEdit {
                    Button(ImaginariumCopy.sendToReady.text) { Task { await model.submit(.ready, projectID: project.id) } }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(promptIsEmpty)
                    Button(ImaginariumCopy.saveToIdeas.text) { Task { await model.submit(.ideas, projectID: project.id) } }
                        .buttonStyle(.link)
                        .disabled(promptIsEmpty)
                }
            }
            switch model.state {
            case .saving:
                ProgressView(ImaginariumCopy.saving.text).controlSize(.small)
            case .checking:
                ProgressView(ImaginariumCopy.checking.text).controlSize(.small)
            case .failed(let message):
                Text(verbatim: message).foregroundStyle(Tokens.Tone.stop.foreground)
                if !model.canEdit {
                    Button(ImaginariumCopy.tryAgain.text) { Task { await model.retry() } }
                }
            case .editing, .saved:
                EmptyView()
            }
        }
        .font(.system(size: Tokens.FontSize.body))
    }

    private var promptIsEmpty: Bool { model.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func confirmation(_ state: TaskState, reason: String?) -> some View {
        VStack(spacing: 12) {
            Image(systemName: state == .backlog ? "exclamationmark.circle" : "checkmark.circle.fill")
                .font(.system(size: 34))
                .foregroundStyle(state == .backlog ? Tokens.Tone.wait.foreground : Tokens.Palette.ok)
                .accessibilityHidden(true)
            Text(ImaginariumCopy.savedTitle(state).text)
                .font(.system(size: 23, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            if let reason {
                Text(verbatim: reason).foregroundStyle(Tokens.Palette.text2)
            }
            HStack {
                Button(ImaginariumCopy.seeOnBoard.text) {
                    context.navigator.showProjectAlone(model.savedProjectID)
                    dismiss()
                }
                .buttonStyle(PrimaryButtonStyle())
                Button(ImaginariumCopy.keepBrowsing.text) { dismiss() }
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(26)
    }
}

/// One Make it yours fill-in of the Try it sheet, its label above it: the
/// field opens holding its default, so a placeholder would never show.
struct ImaginariumFillField: View {
    let label: String
    @Binding var value: String

    var body: some View {
        FormField(label: label) {
            TextField(label, text: $value)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
        }
    }
}

private struct ImaginariumArt: View {
    let category: String

    private var theme: (String, Color, Color) {
        switch category {
        case "pictures": ("paintpalette.fill", .pink, .purple)
        case "websites": ("globe", .cyan, .blue)
        case "apps": ("macwindow", .indigo, .purple)
        case "games": ("gamecontroller.fill", .purple, .blue)
        case "automations": ("bolt.fill", .orange, .pink)
        case "gifts": ("gift.fill", .pink, .red)
        case "learning": ("book.fill", .blue, .teal)
        default: ("house.fill", .teal, .indigo)
        }
    }

    var body: some View {
        let (symbol, start, end) = theme
        Rectangle()
            .fill(LinearGradient(colors: [start, end], startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: 36, weight: .medium))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}
