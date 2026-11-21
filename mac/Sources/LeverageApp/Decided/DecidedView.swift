import LeverageKit
import SwiftUI

struct DecidedView: View {
    @Environment(ScreenContext.self) private var context
    @State private var box = ScreenModelBox<DecidedModel>()

    var body: some View {
        let model = box.model { DecidedModel(api: context.owner) }
        DecidedContent(model: model)
            .task { await model.watch(using: context.feed) }
    }
}

struct DecidedContent: View {
    @Bindable var model: DecidedModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch model.state {
            case .loading:
                Text(DecidedCopy.loading.text)
            case .loaded:
                if model.rows.isEmpty { Text(DecidedCopy.empty.text) }
            case .failed(let copy):
                HStack {
                    Text(copy.text).foregroundStyle(Tokens.Tone.stop.foreground)
                    Button(ShellCopy.tryAgain.text) { Task { await model.load() } }
                        .buttonStyle(.link)
                }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(model.rows, id: \.decidedRowID) { decision in
                        DecidedRowView(decision: decision, model: model)
                    }
                }
            }
        }
    }
}

struct DecidedRowView: View {
    let decision: Decision
    @Bindable var model: DecidedModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: decision.taskTitle.isEmpty ? DecidedCopy.deletedTask.text : decision.taskTitle)
                .font(.system(size: Tokens.FontSize.body, weight: .semibold))
            Text(verbatim: decision.summary)
            if decision.overturnEffect == nil, let answer = decision.outcome {
                Text(verbatim: answer)
            }
            Text(verbatim: model.mark(for: decision))
                .font(.system(size: Tokens.FontSize.small))
                .foregroundStyle(Tokens.Palette.text2)
            if decision.kind == .approval, decision.started, !model.canUndo(decision) {
                Text(DecidedCopy.mayHaveGoneOut.text)
                    .font(.system(size: Tokens.FontSize.small))
                    .foregroundStyle(Tokens.Tone.wait.foreground)
            }
            if let effect = model.effect(for: decision) {
                Text(verbatim: effect)
            }
            if let selected = model.confirming, selected.decidedRowID == decision.decidedRowID {
                confirmation(for: selected)
            } else if model.canUndo(decision) || model.canRecordObjection(decision) {
                let copy = model.canRecordObjection(decision) ? DecidedCopy.recordObjection : .undo
                Button(copy.text) { model.requestUndo(decision) }
                    .disabled(model.confirming != nil)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Tokens.Palette.surface, in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
        .overlay {
            RoundedRectangle(cornerRadius: Tokens.Radius.card).strokeBorder(Tokens.Palette.line)
        }
        .accessibilityElement(children: .contain)
    }

    private func confirmation(for decision: Decision) -> some View {
        let recordedOnly = decision.kind == .approval && decision.actionState == .done
        let prompt: DecidedCopy = if recordedOnly {
            .recordObjectionQuestion
        } else {
            decision.kind == .question ? .undoQuestion : .undoApproval
        }
        return VStack(alignment: .leading, spacing: 8) {
            Text(prompt.text)
            if decision.kind == .question {
                TextField(DecidedCopy.newAnswerField.text, text: $model.answer, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!model.canEditAnswer)
            }
            HStack {
                Button((recordedOnly ? DecidedCopy.recordObjection : .undo).text) {
                    Task { await model.confirmUndo() }
                }
                    .buttonStyle(PrimaryButtonStyle())
                Button(DecidedCopy.goBack.text) { model.dismissUndo() }
            }
            .disabled(model.busy)
            if let failure = model.failure {
                Text(failure.text).foregroundStyle(Tokens.Tone.stop.foreground)
            }
        }
    }
}
