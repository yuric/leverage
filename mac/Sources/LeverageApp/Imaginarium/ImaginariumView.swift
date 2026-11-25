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
            ContentUnavailableView("The prompt catalog is unavailable", systemImage: "sparkles")
        }
    }

    private func hero(_ catalog: ImaginariumCatalog) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Make something on your Mac")
                .font(.system(size: 34, weight: .bold))
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: 12) {
                TextField("Search prompts", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Search prompts")
                Button {
                    selected = catalog.entries.randomElement()
                } label: {
                    Label("Surprise me", systemImage: "shuffle")
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
                filter("All", value: nil)
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
            ContentUnavailableView("No matching prompts", systemImage: "magnifyingglass")
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 14, alignment: .top)], spacing: 14) {
                ForEach(filtered) { entry in
                    tile(entry, categoryName: catalog.categories.first { $0.id == entry.category }?.name ?? entry.category)
                }
            }
        }
    }

    private func tile(_ entry: ImaginariumCatalog.Entry, categoryName: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ImaginariumArt(category: entry.category)
                .frame(height: 108)
                .overlay(alignment: .topLeading) {
                    Chip(text: categoryName, tone: .plain).padding(10)
                }
                .overlay(alignment: .topTrailing) {
                    Chip(text: ImaginariumArt.estimate(entry.minutes), tone: .plain).padding(10)
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
                    Label("Needs an agent with an image tool", systemImage: "photo")
                        .font(.system(size: Tokens.FontSize.small))
                        .foregroundStyle(Tokens.Tone.wait.foreground)
                }
                HStack(spacing: 8) {
                    Button("Try it") { selected = entry }
                        .buttonStyle(PrimaryButtonStyle())
                        .accessibilityLabel("Try \(entry.title)")
                    Button {
                        Pasteboard.copy(entry.filledPrompt())
                        copiedEntryID = entry.id
                    } label: {
                        Image(systemName: copiedEntryID == entry.id ? "checkmark" : "document.on.document")
                    }
                    .help(copiedEntryID == entry.id ? "Copied" : "Copy prompt")
                    .accessibilityLabel(copiedEntryID == entry.id ? "Copied" : "Copy \(entry.title) prompt")
                    if copiedEntryID == entry.id {
                        Text("Copied").font(.system(size: Tokens.FontSize.small))
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
                    .accessibilityLabel("Close")
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
            Text(ImaginariumArt.estimate(model.entry.minutes))
                .font(.system(size: Tokens.FontSize.small, weight: .semibold))
                .foregroundStyle(Tokens.Palette.text2)
            Text(verbatim: model.entry.title)
                .font(.system(size: 28, weight: .bold))
                .accessibilityAddTraits(.isHeader)
            Text(verbatim: model.entry.description)
                .foregroundStyle(Tokens.Palette.text2)
            if model.entry.needs.contains(.imageTool) {
                Label("Needs an agent with an image tool", systemImage: "photo")
                    .foregroundStyle(Tokens.Tone.wait.foreground)
            }
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Make it yours").font(.headline)
                    ForEach(model.entry.fills, id: \.key) { fill in
                        TextField(fill.label, text: fillValue(fill))
                            .textFieldStyle(.roundedBorder)
                    }
                    Text("Done when").font(.headline)
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
                Text("Prompt").font(.headline)
                Spacer()
                Button(model.isEditingPrompt ? "Done editing" : "Edit prompt") {
                    model.isEditingPrompt.toggle()
                }
                .disabled(!model.canEdit)
            }
            Group {
                if model.isEditingPrompt {
                    TextEditor(text: $model.prompt)
                        .scrollContentBackground(.hidden)
                        .accessibilityLabel("Prompt")
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
                Text("Fill-ins leave your edited prompt as written.")
                    .font(.system(size: Tokens.FontSize.small))
                    .foregroundStyle(Tokens.Palette.text2)
                Button("Undo my edits") { model.undoEdits() }
                    .buttonStyle(.link)
                    .disabled(!model.canEdit)
            }
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let project {
                Label("Goes to \(project.name)", systemImage: "folder")
            } else {
                Text("The Imaginarium project is unavailable.")
                    .foregroundStyle(Tokens.Tone.wait.foreground)
            }
            HStack {
                Button(copied ? "Copied" : "Copy prompt") {
                    Pasteboard.copy(model.prompt)
                    copied = true
                }
                if let project, model.canEdit {
                    Button("Send to Ready") { Task { await model.submit(.ready, projectID: project.id) } }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(promptIsEmpty)
                    Button("Save to Ideas") { Task { await model.submit(.ideas, projectID: project.id) } }
                        .buttonStyle(.link)
                        .disabled(promptIsEmpty)
                }
            }
            switch model.state {
            case .saving:
                ProgressView("Saving task…").controlSize(.small)
            case .checking:
                ProgressView("Waiting for a rule check…").controlSize(.small)
            case .failed(let message):
                Text(verbatim: message).foregroundStyle(Tokens.Tone.stop.foreground)
                if !model.canEdit {
                    Button("Try again") { Task { await model.retry() } }
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
            Text(savedTitle(state))
                .font(.system(size: 23, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            if let reason {
                Text(verbatim: reason).foregroundStyle(Tokens.Palette.text2)
            }
            HStack {
                Button("See it on the board") {
                    context.navigator.selectProject(model.savedProjectID)
                    dismiss()
                }
                .buttonStyle(PrimaryButtonStyle())
                Button("Keep browsing") { dismiss() }
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(26)
    }

    private func savedTitle(_ state: TaskState) -> String {
        switch state {
        case .ready: "Sent to Ready"
        case .ideas: "Saved to Ideas"
        default: "Saved to Backlog"
        }
    }
}

private struct ImaginariumArt: View {
    let category: String

    static func estimate(_ minutes: Int) -> String { "About \(minutes) min" }

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
