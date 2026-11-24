import SwiftUI

/// The setup assistant: the full-window sequence a new installation opens
/// on (docs/onboarding/setup-assistant.html). Built with no arguments; the
/// shell puts its `ScreenContext` in the environment.
struct SetupAssistantView: View {
    @Environment(ScreenContext.self) private var context
    @State private var box = ScreenModelBox<SetupAssistantModel>()

    var body: some View {
        let model = box.model {
            SetupAssistantModel(
                setup: context.setup, api: context.owner, helper: context.runtime.helper,
                navigator: context.navigator)
        }
        SetupAssistantContent(model: model)
            .onDisappear { model.cancelSignIn() }
    }
}

/// The assistant drawn from its model: the steps across the top, "Set up
/// later" at the top right, and the current screen in a centered column.
struct SetupAssistantContent: View {
    let model: SetupAssistantModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                SetupStepper(model: model)
                HStack {
                    Spacer(minLength: 0)
                    Button(SetupAssistantCopy.setUpLater.text) { model.skip() }
                        .buttonStyle(AssistantLinkStyle())
                }
            }
            .frame(minHeight: 44)

            screen
                .id(model.screen)
                .transition(reduceMotion ? .identity : .opacity.combined(with: .offset(y: 4)))
                .frame(maxWidth: model.screen == .firstTask ? 700 : 620)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, 26)
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 18)
        .padding(Tokens.Spacing.window)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: model.screen)
    }

    @ViewBuilder
    private var screen: some View {
        switch model.screen {
        case .welcome: SetupWelcomeScreen(model: model)
        case .firstLogin, .secondLogin: SetupLoginScreen(model: model)
        case .agents: SetupAgentsScreen(model: model)
        case .firstTask: SetupFirstTaskScreen(model: model)
        }
    }
}

/// The four steps: a number, a tick once passed, and the current one in blue.
struct SetupStepper: View {
    let model: SetupAssistantModel

    var body: some View {
        HStack(spacing: 8) {
            ForEach(SetupAssistantModel.Stage.allCases, id: \.self) { stage in
                if stage != .welcome {
                    Rectangle()
                        .fill(Tokens.Palette.field.opacity(0.6))
                        .frame(width: 26, height: 1)
                        .accessibilityHidden(true)
                }
                item(stage)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(SetupAssistantCopy.stepsLabel.text))
    }

    private func item(_ stage: SetupAssistantModel.Stage) -> some View {
        let current = stage == model.stage
        let done = model.isDone(stage)
        return HStack(spacing: 6) {
            ZStack {
                if current {
                    Circle().fill(Tokens.Palette.primary)
                } else if done {
                    Circle().fill(Tokens.Tone.done.background)
                } else {
                    Circle().strokeBorder(Tokens.Palette.field, lineWidth: 1)
                }
                if done {
                    TickShape()
                        .stroke(Tokens.Tone.done.foreground, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .frame(width: 10, height: 10)
                } else {
                    Text(verbatim: "\(stage.rawValue + 1)")
                        .font(.system(size: Tokens.FontSize.badge, weight: .bold))
                        .foregroundStyle(current ? Tokens.Palette.primaryForeground : Tokens.Palette.text2)
                }
            }
            .frame(width: 20, height: 20)
            Text(stage.copy.text)
                .font(.system(size: Tokens.FontSize.small, weight: .semibold))
                .foregroundStyle(current ? Tokens.Palette.text : Tokens.Palette.text2)
                .lineLimit(1)
                .fixedSize()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            Text(done ? SetupAssistantCopy.stepDone.filled(["step": stage.copy.text]) : stage.copy.text))
        .accessibilityAddTraits(current ? .isSelected : [])
    }
}

/// A small tick, drawn in a square.
struct TickShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.12, y: rect.minY + rect.height * 0.55))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.4, y: rect.minY + rect.height * 0.82))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.9, y: rect.minY + rect.height * 0.22))
        return path
    }
}
