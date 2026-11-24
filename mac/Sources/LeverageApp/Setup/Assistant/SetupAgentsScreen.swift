import SwiftUI

/// Agents: one General agent for each login, named after it, each with a
/// switch. Start agents connects the ones switched on; connecting an agent
/// the app runs also starts it.
struct SetupAgentsScreen: View {
    let model: SetupAssistantModel

    var body: some View {
        AssistantScreen {
            AssistantHeading(.agentsTitle, .agentsBody)
            AssistantList(items: model.agentRows, label: SetupAssistantCopy.agentsLabel.text) { row in
                AgentSwitchRow(model: model, row: row)
            }
            if let note = model.agentNote {
                AssistantNote(text: note.text, wait: true)
            }
            if let line = model.agentFailure {
                AssistantProblem(text: line)
            }
        } footer: {
            AssistantBackButton(model: model)
            Spacer(minLength: 0)
            if model.agentsStarted {
                AssistantPrimaryButton(title: SetupAssistantCopy.continueButton.text, enabled: model.canContinue) {
                    model.next()
                }
            } else {
                AssistantPrimaryButton(
                    title: model.isStartingAgents ? AgentsCopy.starting.text : SetupAssistantCopy.startAgents.text,
                    enabled: model.canStartAgents
                ) {
                    Task { await model.startAgents() }
                }
            }
        }
    }
}

/// "Claude, Personal": General, the login it runs on, and its switch.
private struct AgentSwitchRow: View {
    let model: SetupAssistantModel
    let row: SetupAssistantModel.AgentRow

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: row.login.label)
                    .font(.system(size: Tokens.FontSize.body, weight: .semibold))
                AssistantMuted(text: line)
                if row.isGemini {
                    AssistantMuted(text: SetupAssistantCopy.geminiRowNote.text)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            if row.isConnected {
                Chip(text: SetupAssistantCopy.agentStarted.text, tone: .done)
            }
            HStack(spacing: 8) {
                Text(row.isOn ? AgentsCopy.on.text : AgentsCopy.off.text)
                    .font(.system(size: Tokens.FontSize.small, weight: .semibold))
                    .foregroundStyle(Tokens.Palette.text2)
                    .accessibilityHidden(true)
                Toggle(
                    isOn: Binding(get: { row.isOn }, set: { model.setAgent(row.login.id, on: $0) })
                ) {
                    Text(SetupAssistantCopy.agentSwitch.filled(["login": row.login.label]))
                }
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
                .disabled(row.isConnected || model.isStartingAgents)
            }
        }
        .padding(.vertical, 12)
        .padding(.leading, 16)
        .padding(.trailing, 14)
    }

    private var line: String {
        let state = row.isOn ? AgentsCopy.runsOn.filled(["login": row.login.label]) : AgentsCopy.stateOff.text
        return AgentsCopy.roleLine.filled(["role": AgentsCopy.roleGeneral.text, "state": state])
    }
}
