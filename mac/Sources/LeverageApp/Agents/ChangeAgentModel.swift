import Foundation
import LeverageKit
import Observation

/// The Change sheet of an agent (HM-51, HE-27): its name, strength, on or
/// off, and permissions, plus the login, model and effort for a Native agent.
///
/// Only the fields the owner changed are sent. A model or effort the owner
/// emptied is sent as null, which is the tool's own default. A new login must
/// be one already added; it takes its provider with it, so the model and
/// effort, which belonged to the old tool, are emptied when the provider
/// changes. The change applies the next time the agent starts a run.
///
/// The same change sent again after the network failed goes under the same
/// key; a changed form gets a new one.
@MainActor
@Observable
final class ChangeAgentModel {
    enum Phase: Equatable, Sendable {
        case editing
        case saving
        case done
    }

    var name: String {
        didSet { if name != oldValue { nameLine = nil } }
    }
    var modelName: String {
        didSet {
            guard modelName != oldValue else { return }
            if !effortChoices.contains(where: { $0.value == effort && $0.enabled }) { effort = "" }
        }
    }
    var effort: String
    var credentialID: UUID? {
        didSet {
            guard offersLogin, credentialID != oldValue, provider(of: credentialID) != provider(of: oldValue) else { return }
            modelName = ""
            effort = ""
        }
    }
    var strengthRank: Int
    var enabled: Bool
    var permissions: SeatPermissions

    private(set) var phase: Phase = .editing
    private(set) var nameLine: String?
    private(set) var failure: String?

    @ObservationIgnored private let api: any OwnerAPI
    @ObservationIgnored private let seat: Seat
    @ObservationIgnored private let holdsTask: Bool
    @ObservationIgnored private let originalStrengthRank: Int
    @ObservationIgnored private let allLogins: [ConnectAgentModel.LoginChoice]
    @ObservationIgnored private let onChanged: @MainActor () async -> Void
    @ObservationIgnored private var sent: (request: ChangeSeatRequest, key: IdempotencyKey)?

    init(
        api: any OwnerAPI, seat: Seat, logins: [ConnectAgentModel.LoginChoice], holdsTask: Bool = false,
        onChanged: @escaping @MainActor () async -> Void
    ) {
        self.api = api
        self.seat = seat
        self.holdsTask = holdsTask
        self.allLogins = logins
        self.onChanged = onChanged
        name = seat.name
        modelName = seat.credentialID == nil ? "" : seat.model ?? ""
        effort = seat.effort ?? ""
        credentialID = seat.credentialID
        enabled = seat.enabled
        permissions = seat.permissions
        let stored = seat.strengthRank.flatMap(AgentStrength.init(rawValue:)) ?? .standard
        originalStrengthRank = stored.rawValue
        strengthRank = stored.rawValue
    }

    var title: String { AgentsCopy.changeTitle.filled(["name": seat.name]) }

    // MARK: what the form offers

    /// Only an agent the app runs has a login to change.
    var offersLogin: Bool { seat.credentialID != nil }

    var modelProvider: Provider? { offersLogin ? chosenProvider : nil }

    var modelChoices: [AgentSettingChoice] {
        guard let modelProvider else { return [] }
        let stored = modelProvider == seat.provider && modelName == seat.model ? seat.model : nil
        let version = allLogins.first { $0.id == credentialID }?.toolVersion
        return AgentSettingChoice.models(provider: modelProvider, installed: version, stored: stored)
    }

    var effortChoices: [AgentSettingChoice] {
        guard let modelProvider else { return [] }
        let stored = modelProvider == seat.provider && modelName == seat.model && effort == seat.effort ? effort : nil
        return AgentSettingChoice.efforts(provider: modelProvider, model: modelName, stored: stored)
    }

    /// A stored effort may have no current choices for its model.
    var unavailableEffort: String? {
        guard let modelProvider, modelProvider == seat.provider, modelName == (seat.model ?? ""),
              ModelCatalog.entry(for: modelProvider)?.nativeEffort.value == true,
              let stored = seat.effort, !stored.isEmpty,
              effort.isEmpty || effort == stored, effortChoices.isEmpty
        else { return nil }
        return effort.isEmpty ? AgentsCopy.defaultModel.text : AgentSettingChoice.unavailable(stored).label
    }

    var canClearUnavailableEffort: Bool {
        guard unavailableEffort != nil, !effort.isEmpty, let modelProvider else { return false }
        // The server checks the model whenever the effort changes, so an
        // unlisted model still needs to be replaced before changing effort.
        return modelName.isEmpty || ModelCatalog.entry(for: modelProvider)?.model(modelName) != nil
    }

    func clearUnavailableEffort() {
        guard phase == .editing, canClearUnavailableEffort else { return }
        effort = ""
    }

    var reportedSettings: String? {
        guard !offersLogin else { return nil }
        guard let model = seat.model, !model.isEmpty else { return AgentsCopy.notReported.text }
        let settings = [model, seat.effort ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
        return AgentsCopy.reportedModel.filled(["settings": settings])
    }

    var deliverNote: String? {
        holdsTask && seat.permissions.deliver && !permissions.deliver ? AgentsCopy.deliverOffNote.text : nil
    }

    /// The logins the agent can move to: a Gemini login is left out for a
    /// Reviewer, which the runner cannot do yet (CL-8).
    var loginChoices: [ConnectAgentModel.LoginChoice] {
        seat.role == .reviewer ? allLogins.filter { $0.provider != .gemini } : allLogins
    }

    var geminiHiddenForReviewer: Bool {
        seat.role == .reviewer && allLogins.contains { $0.provider == .gemini }
    }

    var offersEffort: Bool { !effortChoices.isEmpty }

    /// What turning the agent on or off does (HE-27); nothing until the switch moves.
    var enabledNote: String? {
        guard enabled != seat.enabled else { return nil }
        return (enabled ? AgentsCopy.turnOnNote : AgentsCopy.turnOffNote).text
    }

    var isBusy: Bool { phase == .saving }

    private func provider(of login: UUID?) -> Provider {
        allLogins.first { $0.id == login }?.provider ?? seat.provider
    }

    private var chosenProvider: Provider { provider(of: credentialID) }

    // MARK: what would be sent

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private static func setting(_ value: String, was: String?) -> Setting<String> {
        guard value != (was ?? "") else { return .keep }
        return value.isEmpty ? .clear : .set(value)
    }

    /// The change, or nil when nothing differs or the form is not valid: an
    /// empty name, or a login that is not one of the choices.
    var request: ChangeSeatRequest? {
        guard !trimmedName.isEmpty, AgentStrength(rawValue: strengthRank) != nil else { return nil }
        var login: Setting<UUID> = .keep
        if offersLogin, credentialID != seat.credentialID {
            guard let chosen = credentialID, loginChoices.contains(where: { $0.id == chosen }) else { return nil }
            login = .set(chosen)
        }
        let model = offersLogin ? Self.setting(modelName, was: seat.model) : .keep
        let effortSetting = offersLogin ? Self.setting(effort, was: seat.effort) : .keep
        if case .set(let value) = model, !modelChoices.contains(where: { $0.value == value && $0.enabled }) {
            return nil
        }
        if case .set(let value) = effortSetting, !effortChoices.contains(where: { $0.value == value && $0.enabled }) {
            return nil
        }
        let request = ChangeSeatRequest(
            name: trimmedName != seat.name ? trimmedName : nil,
            model: model,
            effort: effortSetting,
            strengthRank: strengthRank != originalStrengthRank ? .set(strengthRank) : .keep,
            credentialID: login,
            enabled: enabled != seat.enabled ? enabled : nil,
            permissions: permissions != seat.permissions ? permissions : nil)
        return request == ChangeSeatRequest() ? nil : request
    }

    var canSave: Bool { phase == .editing && request != nil }

    // MARK: saving

    func save() async {
        guard phase == .editing, let request else { return }
        phase = .saving
        failure = nil
        nameLine = nil
        let key = (sent?.request == request ? sent?.key : nil) ?? IdempotencyKey()
        sent = (request, key)
        do {
            let outcome = try await api.changeSeat(seatID: seat.id, request, key: key)
            _ = try outcome.completedResult()
            sent = nil
            phase = .done
            await onChanged()
        } catch is CancellationError {
            phase = .editing
        } catch {
            phase = .editing
            if CommandKey.wasAnswered(error) { sent = nil }
            if case LeverageClientError.refused(let refusal) = error, refusal.code == .duplicateName {
                nameLine = ShellCopy.refusalDuplicateName.text
            } else {
                failure = ShellCopy.sentence(for: error).text
            }
        }
    }
}
