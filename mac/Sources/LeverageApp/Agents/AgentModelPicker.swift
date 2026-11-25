import Foundation
import LeverageKit
import SwiftUI

/// One choice in the model or effort picker for a Native agent.
struct AgentSettingChoice {
    let value: String
    let label: String
    let enabled: Bool

    static let toolDefault = Self(value: "", label: AgentsCopy.defaultModel.text, enabled: true)

    static func unavailable(_ value: String) -> Self {
        Self(value: value, label: AgentsCopy.notOffered.filled(["value": value]), enabled: false)
    }

    static func model(_ value: String, provider: Provider, minimum: String?, installed: String?) -> Self {
        if let minimum, let installed, isOlder(installed, than: minimum) {
            let label = AgentsCopy.needsNewerTool.filled([
                "value": value, "tool": ProviderNames.tool(provider), "version": minimum,
            ])
            return Self(value: value, label: label, enabled: false)
        }
        return Self(value: value, label: value, enabled: true)
    }

    /// Readings can include a tool name before the version. Unknown versions
    /// leave the choice available, as when there is no reading yet.
    private static func isOlder(_ installed: String, than minimum: String) -> Bool {
        func components(_ version: String) -> [Int]? {
            guard let range = version.range(of: #"[0-9]+(?:\.[0-9]+)+"#, options: .regularExpression) else {
                return nil
            }
            var numbers = version[range].split(separator: ".").compactMap { Int($0) }
            while numbers.last == 0 { numbers.removeLast() }
            return numbers
        }
        guard let current = components(installed), let required = components(minimum) else { return false }
        return current.lexicographicallyPrecedes(required)
    }

    static func models(provider: Provider, installed: String?, stored: String? = nil) -> [Self] {
        let models = ModelCatalog.entry(for: provider)?.models ?? []
        var choices = [toolDefault]
        if let stored, !stored.isEmpty, !models.contains(where: { $0.id == stored }) {
            choices.append(unavailable(stored))
        }
        return choices + models.map { model in
            Self.model(model.id, provider: provider, minimum: model.minToolVersion, installed: installed)
        }
    }

    static func efforts(provider: Provider, model: String, stored: String? = nil) -> [Self] {
        guard let catalog = ModelCatalog.entry(for: provider), catalog.nativeEffort.value else { return [] }
        let efforts = catalog.efforts(for: model)
        guard !efforts.isEmpty else { return [] }
        var choices = [toolDefault]
        if let stored, !stored.isEmpty, !efforts.contains(stored) {
            choices.append(unavailable(stored))
        }
        return choices + efforts.map { Self(value: $0, label: $0, enabled: true) }
    }
}

struct AgentModelPicker: View {
    let label: String
    let choices: [AgentSettingChoice]
    @Binding var selection: String

    var body: some View {
        FormField(label: label) {
            Picker(label, selection: $selection) {
                ForEach(choices, id: \.value) { choice in
                    Text(verbatim: choice.label).tag(choice.value).disabled(!choice.enabled)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
        }
    }
}

struct AgentPermissionsFields: View {
    @Binding var permissions: SeatPermissions
    var deliverNote: String? = nil

    var body: some View {
        FormField(label: AgentsCopy.permissionHeading.text) {
            VStack(alignment: .leading, spacing: 6) {
                Toggle(AgentsCopy.mayWork.text, isOn: $permissions.work)
                Toggle(AgentsCopy.mayDeliver.text, isOn: $permissions.deliver)
                if let deliverNote {
                    Text(verbatim: deliverNote)
                        .font(.system(size: Tokens.FontSize.small))
                        .foregroundStyle(Tokens.Palette.text2)
                }
                Toggle(AgentsCopy.mayCreate.text, isOn: $permissions.create)
            }
            .toggleStyle(.checkbox)
        }
    }
}
