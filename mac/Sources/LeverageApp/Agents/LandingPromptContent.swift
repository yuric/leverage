import SwiftUI

/// The one-time prompt and Copy control in Connect.
struct LandingPromptContent: View {
    let model: LandingPromptModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(AgentsCopy.landingTitle.text)
                .font(.system(size: Tokens.FontSize.body, weight: .semibold))
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
                Text(AgentsCopy.landingNote.text)
                    .font(.system(size: Tokens.FontSize.small))
                    .foregroundStyle(Tokens.Palette.text2)
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
