import SwiftUI

/// The same one-time prompt and Copy control in Connect and New prompt.
struct LandingPromptContent: View {
    let model: LandingPromptModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(AgentsCopy.landingTitle.text)
                .font(.system(size: Tokens.FontSize.body, weight: .semibold))
            Text(AgentsCopy.landingNote.text)
                .font(.system(size: Tokens.FontSize.small))
                .foregroundStyle(Tokens.Palette.text2)
            switch model.state {
            case .none:
                EmptyView()
            case .loading:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(AgentsCopy.landingLoading.text)
                        .font(.system(size: Tokens.FontSize.small))
                        .foregroundStyle(Tokens.Palette.text2)
                }
            case .ready(let text):
                Text(verbatim: text)
                    .font(.system(size: Tokens.FontSize.small, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        Tokens.Palette.inset,
                        in: RoundedRectangle(cornerRadius: Tokens.Radius.control, style: .continuous))
                Button(model.copied ? AgentsCopy.copied.text : AgentsCopy.copy.text) { model.copyPrompt() }
            case .failed(let line):
                Text(verbatim: line)
                    .font(.system(size: Tokens.FontSize.body, weight: .medium))
                    .foregroundStyle(Tokens.Tone.stop.foreground)
                Button(AgentsCopy.landingRetry.text) { Task { await model.issue() } }
            }
        }
    }
}

struct NewLandingPromptSheet: View {
    let model: LandingPromptModel
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(AgentsCopy.newPrompt.text)
                .font(.system(size: 20, weight: .semibold))
            if model.state == .none {
                Text(AgentsCopy.landingNote.text)
                    .foregroundStyle(Tokens.Palette.text2)
            } else {
                LandingPromptContent(model: model)
            }
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                if model.state == .none {
                    Button(AgentsCopy.cancel.text, action: dismiss)
                        .keyboardShortcut(.cancelAction)
                    Button(AgentsCopy.newPrompt.text) { Task { await model.issue() } }
                        .buttonStyle(PrimaryButtonStyle())
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(AgentsCopy.done.text, action: dismiss)
                        .buttonStyle(PrimaryButtonStyle())
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.state == .loading)
                }
            }
        }
        .padding(Tokens.Spacing.sheet)
        .frame(width: 480)
        .background(Tokens.Palette.sheet)
        .interactiveDismissDisabled(model.state == .loading)
    }
}
