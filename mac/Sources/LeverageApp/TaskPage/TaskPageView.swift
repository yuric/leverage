import SwiftUI

/// The task page, opened from a card (MA-9). Built with no arguments: it shows
/// the task the navigator has open. The shell draws "Back to the board".
struct TaskPageView: View {
    @Environment(ScreenContext.self) private var context

    var body: some View {
        if let id = context.navigator.openTaskID {
            TaskPageHost(taskID: id).id(id)
        } else {
            Text(TaskPageCopy.noTask.text)
                .font(.system(size: Tokens.FontSize.body))
                .foregroundStyle(Tokens.Palette.text2)
        }
    }
}

/// Owns the view model of one task's page for as long as it is open.
private struct TaskPageHost: View {
    let taskID: UUID
    @Environment(ScreenContext.self) private var context
    @State private var box = ScreenModelBox<TaskPageModel>()

    var body: some View {
        let model = box.model {
            TaskPageModel(
                taskID: taskID, api: context.owner, noteRead: { [feed = context.feed] in feed.noteRead(asOfSeq: $0) })
        }
        TaskPageContent(model: model)
            .task {
                model.attach(to: context.feed)
                await model.load()
            }
            .onDisappear { model.detach() }
    }
}

/// What the page draws from its model.
struct TaskPageContent: View {
    @Bindable var model: TaskPageModel

    var body: some View {
        switch model.state {
        case .loading:
            plain(TaskPageCopy.loading.text)
        case .notFound:
            plain(ShellCopy.transportNotFound.text)
        case .signedOut:
            plain(ShellCopy.transportUnauthenticated.text)
        case .failed(let copy) where model.page == nil:
            plain(copy.text, tone: Tokens.Tone.stop.foreground)
        case .loaded, .failed:
            page
        }
    }

    private func plain(_ text: String, tone: Color = Tokens.Palette.text2) -> some View {
        Text(verbatim: text)
            .font(.system(size: Tokens.FontSize.body))
            .foregroundStyle(tone)
    }

    private var page: some View {
        ScrollView {
            TaskPageBody(model: model)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 6)
                .padding(.bottom, 12)
        }
        .sheet(
            isPresented: Binding(get: { model.editor != nil }, set: { if !$0 { model.endEditing() } })
        ) {
            if let editor = model.editor {
                EditContractSheet(model: editor, cancel: { model.endEditing() })
            }
        }
        .confirmationDialog(
            TaskPageCopy.cancelQuestion.text,
            isPresented: Binding(get: { model.isConfirmingCancel }, set: { if !$0 { model.dismissCancel() } }),
            titleVisibility: .visible
        ) {
            Button(TaskPageCopy.cancelTask.text, role: .destructive) { Task { await model.confirmCancel() } }
            Button(TaskPageCopy.keepTask.text, role: .cancel) { model.dismissCancel() }
        } message: {
            Text(TaskPageCopy.cancelExplanation.text)
        }
    }

}

/// The page's sections, one under another.
struct TaskPageBody: View {
    @Bindable var model: TaskPageModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if case .failed(let copy) = model.state {
                Text(verbatim: copy.text)
                    .font(.system(size: Tokens.FontSize.body))
                    .foregroundStyle(Tokens.Tone.stop.foreground)
            }
            header
            actions
            if model.needsRoundDecision { roundDecision }
            if let failure = model.actionFailure {
                Text(verbatim: failure.text)
                    .font(.system(size: Tokens.FontSize.body))
                    .foregroundStyle(Tokens.Tone.stop.foreground)
            }
            if model.showsContractForm { contractForm } else { contract }
            criteria
            work
            log
        }
    }

    // MARK: the pieces

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: model.title)
                    .font(.system(size: 20, weight: .semibold))
                if let status = model.status {
                    Text(verbatim: status.statusLine)
                        .font(.system(size: Tokens.FontSize.body))
                        .foregroundStyle(Tokens.Palette.text2)
                    if let chip = status.chip { Chip(text: chip.text, tone: chip.tone) }
                    if let note = status.note { noteBox(note) }
                }
            }
            Spacer(minLength: 0)
            if model.canCancel {
                Menu {
                    Button(TaskPageCopy.cancelTask.text, role: .destructive) { model.askToCancel() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel(TaskPageCopy.cancelTask.text)
            }
        }
    }

    /// What the owner can do with the task besides cancelling it (HM-45, HM-49).
    @ViewBuilder
    private var actions: some View {
        if model.canMoveToBacklog || model.canChangeTask || model.canPause || model.canContinue {
            HStack(spacing: 10) {
                if model.canMoveToBacklog {
                    Button(TaskPageCopy.moveToBacklog.text) { Task { await model.moveToBacklog() } }
                        .buttonStyle(PrimaryButtonStyle())
                }
                if model.canChangeTask {
                    Button(TaskPageCopy.changeTask.text) { model.beginEditing() }
                }
                if model.canPause {
                    Button(TaskPageCopy.pauseTask.text) { Task { await model.pauseTask() } }
                }
                if model.canContinue {
                    Button(TaskPageCopy.continueTask.text) { Task { await model.continueTask() } }
                        .buttonStyle(PrimaryButtonStyle())
                }
                if model.isBusy { ProgressView().controlSize(.small) }
            }
        }
    }

    private func noteBox(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.system(size: Tokens.FontSize.small))
            .foregroundStyle(Tokens.Palette.text2)
            .padding(8)
            .background(
                Tokens.Palette.inset, in: RoundedRectangle(cornerRadius: Tokens.Radius.control, style: .continuous))
    }

    private var roundDecision: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(TaskPageCopy.pausedAtLimit.text)
                .font(.system(size: Tokens.FontSize.body, weight: .semibold))
            HStack(spacing: 10) {
                Button(TaskPageCopy.allowOneMoreTry.text) { Task { await model.allowAnotherRound() } }
                    .buttonStyle(PrimaryButtonStyle())
                if model.canChangeTask {
                    Button(TaskPageCopy.changeTask.text) { model.beginEditing() }
                }
                Button(TaskPageCopy.cancelTask.text, role: .destructive) { model.askToCancel() }
                if model.isBusy { ProgressView().controlSize(.small) }
            }
            .disabled(model.isBusy)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.Tone.stop.background, in: RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous))
    }

    private func section<Content: View>(_ title: TaskPageCopy, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.text)
                .font(.system(size: Tokens.FontSize.small, weight: .semibold))
                .foregroundStyle(Tokens.Palette.text2)
            content()
        }
    }

    private var contract: some View {
        VStack(alignment: .leading, spacing: 18) {
            section(.sectionGoal) {
                Text(verbatim: model.goal).font(.system(size: Tokens.FontSize.body))
            }
            if let details = model.details {
                section(.sectionDetails) {
                    Text(verbatim: details).font(.system(size: Tokens.FontSize.body))
                }
            }
            HStack(spacing: 6) {
                Text(AddTaskCopy.priorityLabel.text)
                    .foregroundStyle(Tokens.Palette.text2)
                Text(verbatim: model.priorityText)
            }
            .font(.system(size: Tokens.FontSize.body))
        }
    }

    /// A task left in Backlog: the form filled in, and Send to agents (MA-16).
    private var contractForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(TaskPageCopy.backlogHint.text)
                .font(.system(size: Tokens.FontSize.body))
                .foregroundStyle(Tokens.Palette.text2)
            FormField(label: AddTaskCopy.titleLabel.text) {
                TextField(AddTaskCopy.titlePlaceholder.text, text: $model.draft.title)
                    .textFieldStyle(.roundedBorder)
            }
            FormField(label: AddTaskCopy.goalLabel.text, hint: AddTaskCopy.goalHint.text) {
                TextField(AddTaskCopy.goalPlaceholder.text, text: $model.draft.goal)
                    .textFieldStyle(.roundedBorder)
            }
            FormField(label: AddTaskCopy.criteriaLabel.text, hint: AddTaskCopy.criteriaHint.text) {
                PlaceholderEditor(text: $model.draft.criteriaText, placeholder: AddTaskCopy.criteriaPlaceholder.text)
            }
            FormField(label: AddTaskCopy.detailsLabel.text) {
                PlaceholderEditor(
                    text: $model.draft.details, placeholder: AddTaskCopy.detailsPlaceholder.text, minHeight: 48)
            }
            FormField(label: AddTaskCopy.workLabel.text, hint: AddTaskCopy.workHint.text) {
                TextField(AddTaskCopy.workPlaceholder.text, text: $model.draft.workReference)
                    .textFieldStyle(.roundedBorder)
            }
            HStack(spacing: 10) {
                Button(TaskPageCopy.sendToAgents.text) { Task { await model.sendToAgents() } }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!model.canSend)
                if model.isBusy {
                    ProgressView().controlSize(.small)
                    Text(TaskPageCopy.sending.text)
                        .font(.system(size: Tokens.FontSize.small))
                        .foregroundStyle(Tokens.Palette.text2)
                }
            }
        }
    }

    private var criteria: some View {
        section(.sectionCriteria) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(model.criteria) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: row.isDone ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(row.isDone ? Tokens.Palette.ok : Tokens.Palette.text2)
                                .accessibilityHidden(true)
                            Text(verbatim: row.text).font(.system(size: Tokens.FontSize.body))
                            Spacer(minLength: 8)
                            Text(verbatim: row.stateText)
                                .font(.system(size: Tokens.FontSize.small))
                                .foregroundStyle(Tokens.Palette.text2)
                        }
                        ForEach(row.evidence) { evidence in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(verbatim: evidence.kindText)
                                    .font(.system(size: Tokens.FontSize.badge, weight: .semibold))
                                    .foregroundStyle(Tokens.Palette.text2)
                                Text(verbatim: evidence.value)
                                    .font(.system(size: Tokens.FontSize.small))
                                    .textSelection(.enabled)
                            }
                            .padding(.leading, 26)
                        }
                    }
                }
            }
        }
    }

    private var work: some View {
        section(.sectionWork) {
            if let reference = model.workReference {
                Text(verbatim: reference)
                    .font(.system(size: Tokens.FontSize.body))
                    .textSelection(.enabled)
            } else {
                Text(TaskPageCopy.workNotGiven.text)
                    .font(.system(size: Tokens.FontSize.body))
                    .foregroundStyle(Tokens.Palette.text2)
            }
        }
    }

    private var log: some View {
        section(.sectionLog) {
            if model.log.isEmpty {
                Text(TaskPageCopy.emptyLog.text)
                    .font(.system(size: Tokens.FontSize.body))
                    .foregroundStyle(Tokens.Palette.text2)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.log) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(entry.at.formatted(date: .abbreviated, time: .shortened))
                                .font(.system(size: Tokens.FontSize.small))
                                .foregroundStyle(Tokens.Palette.text2)
                                .frame(width: 170, alignment: .leading)
                            Text(verbatim: entry.text).font(.system(size: Tokens.FontSize.body))
                        }
                    }
                }
            }
        }
    }
}
