import LeverageKit
import SwiftUI

struct ProjectDetailView: View {
    private enum Editor: String, Identifiable {
        case brief, budget
        var id: String { rawValue }
    }

    let model: ProjectDetailModel
    let back: () -> Void
    @State private var editor: Editor?
    @State private var confirmingDeletion = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(ProjectsCopy.back.text, action: back)
                .buttonStyle(.link)
            if let project = model.project {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        heading(project)
                        if project.contentDeletedAt != nil {
                            Text(ProjectsCopy.deletedContent.text)
                                .foregroundStyle(Tokens.Palette.text2)
                        } else {
                            budget
                            brief(project.brief)
                            if model.canDeleteContent {
                                Button(ProjectsCopy.deleteContent.text, role: .destructive) {
                                    confirmingDeletion = true
                                }
                                .disabled(model.isSaving)
                            }
                        }
                        if let failure = model.failure {
                            Text(failure.text).foregroundStyle(Tokens.Tone.stop.foreground)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .sheet(item: $editor) { shown in
                    switch shown {
                    case .brief:
                        ProjectBriefSheet(
                            detail: model, brief: BriefEditorModel(brief: project.brief), dismiss: { editor = nil })
                    case .budget:
                        ProjectBudgetSheet(detail: model, dismiss: { editor = nil })
                    }
                }
                .confirmationDialog(ProjectsCopy.confirmDelete.text, isPresented: $confirmingDeletion, titleVisibility: .visible) {
                    Button(ProjectsCopy.deleteContent.text, role: .destructive) {
                        Task { _ = await model.deleteContent() }
                    }
                    Button(ProjectsCopy.cancel.text, role: .cancel) {}
                } message: {
                    Text(ProjectsCopy.deleteExplanation.text)
                }
            }
        }
    }

    private func heading(_ project: Project) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(verbatim: ProjectsCopy.projectName(project))
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if project.contentDeletedAt == nil {
                    Button((project.paused ? ProjectsCopy.resume : .pause).text) {
                        Task { await model.setPaused(!project.paused) }
                    }
                    .disabled(model.isSaving)
                }
            }
            if !project.goal.isEmpty { Text(verbatim: project.goal) }
            if project.paused, project.contentDeletedAt == nil {
                Text((project.pausedBy == .budget ? ProjectsCopy.pausedForBudget : .paused).text)
                    .foregroundStyle(Tokens.Tone.wait.foreground)
            }
        }
    }

    private var budget: some View {
        GroupBox(ProjectsCopy.budget.text) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(verbatim: model.budgetText)
                    Button(ProjectsCopy.changeBudget.text) { present(.budget) }
                        .buttonStyle(.link)
                        .disabled(model.isSaving)
                }
                LabeledContent(ProjectsCopy.spent.text) { Text(verbatim: model.spentText) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func brief(_ entries: [BriefEntry]) -> some View {
        GroupBox(ProjectsCopy.brief.text) {
            VStack(alignment: .leading, spacing: 8) {
                Button(ProjectsCopy.editBrief.text) { present(.brief) }
                    .buttonStyle(.link)
                    .disabled(model.isSaving)
                if entries.isEmpty {
                    Text(ProjectsCopy.emptyBrief.text).foregroundStyle(Tokens.Palette.text2)
                }
                ForEach(entries, id: \.id) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ProjectsCopy.kind(entry.kind).text).font(.subheadline.weight(.semibold))
                        Text(verbatim: entry.text)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func present(_ editor: Editor) {
        model.clearFailure()
        self.editor = editor
    }
}

private struct ProjectBudgetSheet: View {
    let detail: ProjectDetailModel
    let dismiss: () -> Void
    @State private var amount: String

    init(detail: ProjectDetailModel, dismiss: @escaping () -> Void) {
        self.detail = detail
        self.dismiss = dismiss
        _amount = State(initialValue: detail.budgetInput)
    }

    var body: some View {
        ProjectEditorSheet(
            title: .changeBudget, save: .save, canSave: detail.canChangeBudget(amount),
            isSaving: detail.isSaving, failure: detail.failure, dismiss: dismiss,
            submit: {
                if await detail.changeBudget(amount) { dismiss() }
            }
        ) {
            ProjectBudgetField(amount: $amount)
        }
    }
}

private struct ProjectBriefSheet: View {
    let detail: ProjectDetailModel
    @State var brief: BriefEditorModel
    let dismiss: () -> Void

    var body: some View {
        @Bindable var brief = brief
        ProjectEditorSheet(
            title: .editBrief, save: .save, canSave: brief.request != nil && !detail.isSaving,
            isSaving: detail.isSaving, failure: detail.failure, dismiss: dismiss,
            submit: {
                if await detail.saveBrief(brief) { dismiss() }
            }
        ) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach($brief.entries) { $entry in
                        HStack(alignment: .top, spacing: 6) {
                            Picker(ProjectsCopy.entryKind.text, selection: $entry.kind) {
                                ForEach(BriefEntryKind.allCases, id: \.self) { kind in
                                    Text(ProjectsCopy.kind(kind).text).tag(kind)
                                }
                            }
                            .labelsHidden()
                            .fixedSize()
                            TextField(ProjectsCopy.entryText.text, text: $entry.text, axis: .vertical)
                            moveButton(entry.id, by: -1, copy: .moveUp, symbol: "chevron.up")
                            moveButton(entry.id, by: 1, copy: .moveDown, symbol: "chevron.down")
                            Button { brief.removeEntry(entry.id) } label: { Image(systemName: "minus.circle") }
                                .accessibilityLabel(ProjectsCopy.removeEntry.text)
                        }
                    }
                    Button(ProjectsCopy.addEntry.text) { brief.addEntry() }
                }
            }
            .frame(height: 250)
        }
    }

    private func moveButton(_ id: UUID, by offset: Int, copy: ProjectsCopy, symbol: String) -> some View {
        Button { brief.moveEntry(id, by: offset) } label: { Image(systemName: symbol) }
            .disabled(!brief.canMoveEntry(id, by: offset))
            .accessibilityLabel(copy.text)
    }
}
