import LeverageKit
import SwiftUI

/// The models available to Connect and Change for a Native agent's provider.
struct AgentModelPicker: View {
    let provider: Provider
    let existingModel: String?
    @Binding var selection: String

    /// The empty choice leaves the model to the tool. Change also offers an
    /// already stored model when it is absent from the provider's list.
    var choices: [String] {
        let documented = ProviderCatalog.entry(for: provider.rawValue)?.models.value ?? []
        if let existingModel, !existingModel.isEmpty, !documented.contains(existingModel) {
            return ["", existingModel] + documented
        }
        return [""] + documented
    }

    var body: some View {
        FormField(label: AgentsCopy.modelLabel.text) {
            Picker(AgentsCopy.modelLabel.text, selection: $selection) {
                ForEach(choices, id: \.self) { model in
                    Text(verbatim: model.isEmpty ? AgentsCopy.defaultModel.text : model).tag(model)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
        }
    }
}
