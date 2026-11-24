import LeverageKit
import SwiftUI

/// Settings, Rules (RD-25, RM-2): every rule with its switch, and Add a rule.
/// Built with no arguments; the shell puts its `ScreenContext` in the
/// environment.
struct RulesView: View {
    @Environment(ScreenContext.self) private var context
    @State private var box = ScreenModelBox<RulesModel>()
    @State private var presented: RuleEditorPresentation?

    var body: some View {
        let model = box.model { RulesModel(api: context.owner) }
        RulesContent(
            model: model, change: { present(.change($0.row), model: model) },
            add: { present(.add, model: model) }, projects: context.paneProjects
        )
        .task {
            model.attach(to: context.feed)
            await model.load()
        }
        .onDisappear { model.detach() }
        .sheet(item: $presented) { presentation in
            RuleEditorSheet(
                model: presentation.model, cancel: { presented = nil },
                projects: context.paneProjects, projectListFailure: context.projectListFailure)
        }
    }

    private func present(_ mode: RuleEditorModel.Mode, model: RulesModel) {
        let editor = RuleEditorModel(
            mode: mode, api: context.owner,
            onDone: {
                presented = nil
                Task { await model.load() }
            })
        presented = RuleEditorPresentation(model: editor)
    }
}

/// A sheet that is showing: the editor it was made with.
struct RuleEditorPresentation: Identifiable {
    let id = UUID()
    let model: RuleEditorModel
}

/// What the screen draws from its model.
struct RulesContent: View {
    let model: RulesModel
    let change: (RuleLine) -> Void
    let add: () -> Void
    var projects: [Project] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: RulesCopy.title.text)
                        .font(.system(size: 17, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text(verbatim: RulesCopy.hint.text)
                        .font(.system(size: Tokens.FontSize.body))
                        .foregroundStyle(Tokens.Palette.text2)
                }
                Spacer(minLength: 12)
                Button(RulesCopy.addRule.text, action: add)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    status
                    ruleSection(.orchestratorRules, checker: .model)
                    ruleSection(.otherAgentRules, checker: .app)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func ruleSection(_ title: RulesCopy, checker: RuleChecker) -> some View {
        let lines = model.lines.filter { $0.row.version.checker == checker }
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(verbatim: title.text)
                    .font(.system(size: Tokens.FontSize.body, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                ForEach(lines) { line in
                    RuleRowView(
                        line: line, isChanging: model.changing.contains(line.id),
                        turn: { on in Task { await model.setEnabled(line.id, to: on) } },
                        change: { change(line) }, projects: projects)
                }
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        switch model.state {
        case .loading:
            note(RulesCopy.loading.text)
        case .signedOut:
            note(ShellCopy.transportUnauthenticated.text, tone: Tokens.Tone.stop.foreground)
        case .failed(let copy):
            note(copy.text, tone: Tokens.Tone.stop.foreground)
        case .loaded:
            if model.lines.isEmpty { note(RulesCopy.empty.text) }
        }
        if let failure = model.failure {
            note(failure.text, tone: Tokens.Tone.stop.foreground)
        }
    }

    private func note(_ text: String, tone: Color = Tokens.Palette.text2) -> some View {
        Text(verbatim: text)
            .font(.system(size: Tokens.FontSize.body, weight: .medium))
            .foregroundStyle(tone)
    }
}
