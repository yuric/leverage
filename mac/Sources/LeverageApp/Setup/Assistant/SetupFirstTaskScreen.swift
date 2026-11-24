import AppKit
import SwiftUI

/// First task: three ready-made tasks, or one the owner writes, sent to the
/// agents through the Add task form.
struct SetupFirstTaskScreen: View {
    @Bindable var model: SetupAssistantModel
    @FocusState private var titleFocused: Bool

    var body: some View {
        AssistantScreen {
            AssistantHeading(.taskTitle, .taskBody)
            HStack(alignment: .top, spacing: 10) {
                ForEach(StarterTask.all) { task in
                    StarterCard(task: task, selected: model.starter == task.kind) { model.choose(task.kind) }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text(SetupAssistantCopy.startersLabel.text))
            if let kind = model.starter {
                StarterDetail(task: StarterTask.task(kind))
            }
            writeOwnButton
            if model.writesOwn {
                ownForm
            }
            if let line = model.taskFailure {
                AssistantProblem(text: line)
            }
        } footer: {
            AssistantBackButton(model: model)
            Spacer(minLength: 0)
            Button(SetupAssistantCopy.skipToBoard.text) { model.skip() }
                .buttonStyle(AssistantLinkStyle(quiet: true))
            AssistantPrimaryButton(
                title: model.isSending ? SetupAssistantCopy.sending.text : SetupAssistantCopy.sendToAgents.text,
                enabled: model.canSend
            ) {
                Task { await model.send() }
            }
        }
    }

    private var writeOwnButton: some View {
        let shape = RoundedRectangle(cornerRadius: Tokens.Radius.control, style: .continuous)
        return Button {
            model.toggleWriteOwn()
            titleFocused = model.writesOwn
        } label: {
            Text(SetupAssistantCopy.writeOwn.text)
                .font(.system(size: Tokens.FontSize.body, weight: model.writesOwn ? .semibold : .regular))
                .foregroundStyle(Tokens.Palette.text)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                .background(Tokens.Palette.control, in: shape)
                .overlay(
                    shape.strokeBorder(
                        model.writesOwn ? Tokens.Palette.focus : Tokens.Palette.line, lineWidth: model.writesOwn ? 2 : 1))
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(model.writesOwn ? .isSelected : [])
    }

    private var ownForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            FormField(label: AddTaskCopy.titleLabel.text) {
                TextField(AddTaskCopy.titlePlaceholder.text, text: $model.ownTitle)
                    .textFieldStyle(.roundedBorder)
                    .focused($titleFocused)
            }
            FormField(label: AddTaskCopy.criteriaLabel.text, hint: AddTaskCopy.criteriaHint.text) {
                TextField(AddTaskCopy.criteriaPlaceholder.text, text: $model.ownCriteria, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(3...6)
            }
            if model.ownNeedsCriteria {
                AssistantNote(text: SetupAssistantCopy.ownNeedsCriteria.text, wait: true)
            }
            AssistantMuted(text: AddTaskCopy.footnoteProviderRule.text)
        }
        .assistantCard(padding: 14)
    }
}

/// A ready-made task in the gallery's vivid style: a gradient with its
/// category and time, then its title and one line.
private struct StarterCard: View {
    let task: StarterTask
    let selected: Bool
    let action: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack {
                    LinearGradient(
                        colors: task.gradient.map { Color(nsColor: NSColor(hex: $0)) },
                        startPoint: UnitPoint(x: 0, y: 0.32), endPoint: UnitPoint(x: 1, y: 0.68))
                    artwork
                        .foregroundStyle(.white)
                        .accessibilityHidden(true)
                    VStack {
                        HStack {
                            chip(task.category.text, background: Color(nsColor: NSColor(hex: 0x141828, alpha: 0.74)),
                                 foreground: .white)
                            Spacer(minLength: 4)
                            chip(task.time.text, background: Color.white.opacity(0.92),
                                 foreground: Color(nsColor: NSColor(hex: 0x1A1E29)))
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(8)
                }
                .frame(height: 86)
                VStack(alignment: .leading, spacing: 4) {
                    Text(task.title.text)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Tokens.Palette.text)
                    AssistantMuted(text: task.pitch.text)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Tokens.Palette.surface)
            .clipShape(shape)
            .overlay(shape.strokeBorder(selected ? Tokens.Palette.focus : Tokens.Palette.line, lineWidth: selected ? 2 : 1))
            .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private var artwork: some View {
        switch task.art {
        case .apps: Image(systemName: "checklist").font(.system(size: 30, weight: .semibold))
        case .web: Image(systemName: "macwindow").font(.system(size: 30, weight: .semibold))
        case .spark: Image(systemName: "sparkles").font(.system(size: 30, weight: .semibold))
        }
    }

    private func chip(_ text: String, background: Color, foreground: Color) -> some View {
        Text(text)
            .font(.system(size: Tokens.FontSize.badge, weight: .bold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(background, in: RoundedRectangle(cornerRadius: Tokens.Radius.chip, style: .continuous))
    }
}

/// The chosen task's Done when list, and how long it takes.
private struct StarterDetail: View {
    let task: StarterTask

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(SetupAssistantCopy.doneWhen.text)
                .font(.system(size: Tokens.FontSize.body, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array((task.doneWhen + [.reviewLine]).enumerated()), id: \.offset) { index, line in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(verbatim: "\(index + 1).")
                            .foregroundStyle(Tokens.Palette.text2)
                            .frame(minWidth: 14, alignment: .trailing)
                        Text(line.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.system(size: Tokens.FontSize.body))
                    .accessibilityElement(children: .combine)
                }
            }
            AssistantMuted(text: SetupAssistantCopy.agentTime.filled(["time": task.time.text]))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .assistantCard()
    }
}
