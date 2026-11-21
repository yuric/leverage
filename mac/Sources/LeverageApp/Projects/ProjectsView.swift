import LeverageKit
import SwiftUI

struct ProjectsView: View {
    @Environment(ScreenContext.self) private var context
    @State private var box = ScreenModelBox<ProjectsModel>()

    var body: some View {
        let model = box.model { ProjectsModel(api: context.owner) }
        ProjectsContent(model: model)
            .task { await model.watch(context.feed) }
    }
}

struct ProjectsContent: View {
    let model: ProjectsModel
    @State private var selection: UUID?
    @State private var creating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if case .failed(let copy) = model.state {
                HStack {
                    Text(copy.text).foregroundStyle(Tokens.Tone.stop.foreground)
                    Button(ShellCopy.tryAgain.text) { Task { await model.load() } }
                        .buttonStyle(.link)
                }
            }
            if let selection {
                ProjectDetailView(
                    model: ProjectDetailModel(projectID: selection, projects: model),
                    back: { self.selection = nil })
                    .id(selection)
            } else {
                projectList
            }
        }
        .sheet(isPresented: $creating) {
            NewProjectSheet(model: model, dismiss: { creating = false })
        }
    }

    private var projectList: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(ProjectsCopy.title.text)
                    .font(.system(size: 17, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button(ProjectsCopy.newProject.text) {
                    model.clearFailure()
                    creating = true
                }
                .disabled(model.isSaving)
            }
            if model.state == .loading { Text(ProjectsCopy.loading.text).foregroundStyle(Tokens.Palette.text2) }
            if model.state == .loaded, model.projects.isEmpty {
                Text(ProjectsCopy.empty.text).foregroundStyle(Tokens.Palette.text2)
            }
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(model.projects, id: \.id) { project in
                        Button {
                            model.clearFailure()
                            selection = project.id
                        } label: {
                            HStack {
                                Image(systemName: "folder")
                                Text(verbatim: ProjectsCopy.projectName(project)).fontWeight(.medium)
                                Spacer()
                                if project.paused, project.contentDeletedAt == nil {
                                    Text(ProjectsCopy.paused.text).foregroundStyle(Tokens.Tone.wait.foreground)
                                }
                                Image(systemName: "chevron.right").foregroundStyle(Tokens.Palette.text2)
                            }
                            .padding(10)
                            .background(Tokens.Palette.field, in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

private struct NewProjectSheet: View {
    let model: ProjectsModel
    let dismiss: () -> Void
    @State private var name = ""
    @State private var goal = ""
    @State private var budget = ""

    var body: some View {
        ProjectEditorSheet(
            title: .newProject, save: .create, canSave: model.canCreate(name: name, budget: budget),
            isSaving: model.isSaving, failure: model.failure, dismiss: dismiss,
            submit: {
                if await model.create(name: name, goal: goal, budget: budget) { dismiss() }
            }
        ) {
            FormField(label: ProjectsCopy.name.text) {
                TextField(ProjectsCopy.name.text, text: $name).labelsHidden()
            }
            FormField(label: ProjectsCopy.goal.text) {
                TextField(ProjectsCopy.goal.text, text: $goal, axis: .vertical).labelsHidden()
            }
            ProjectBudgetField(amount: $budget)
        }
    }
}

struct ProjectBudgetField: View {
    @Binding var amount: String

    var body: some View {
        FormField(label: ProjectsCopy.budgetInUSD.text) {
            TextField(ProjectsCopy.budgetInUSD.text, text: $amount, prompt: Text(ProjectsCopy.noLimit.text))
                .labelsHidden()
        }
    }
}

struct ProjectEditorSheet<Fields: View>: View {
    let title: ProjectsCopy
    let save: ProjectsCopy
    let canSave: Bool
    let isSaving: Bool
    let failure: ShellCopy?
    let dismiss: () -> Void
    let submit: () async -> Void
    @ViewBuilder let fields: () -> Fields

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title.text).font(.system(size: 20, weight: .semibold))
            fields().disabled(isSaving)
            if let failure {
                Text(failure.text).foregroundStyle(Tokens.Tone.stop.foreground)
            }
            HStack(spacing: 10) {
                Spacer()
                if isSaving { ProgressView().controlSize(.small) }
                Button(ProjectsCopy.cancel.text, action: dismiss)
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSaving)
                Button(save.text) { Task { await submit() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!canSave)
            }
        }
        .padding(Tokens.Spacing.sheet)
        .frame(width: 450)
        .background(Tokens.Palette.sheet)
    }
}
