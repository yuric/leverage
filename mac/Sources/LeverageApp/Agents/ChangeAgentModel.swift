import Foundation
import LeverageKit
import Observation

/// The Change sheet of an agent (HM-51, HE-27): its name, model, effort, the
/// login it runs on (for an agent the app runs) and on or off. Strength rank
/// and role are not offered: the rank is not shown (MA-11), and a role cannot
/// change while the agent holds work.
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
    var modelName: String
    var effort: String
    var credentialID: UUID? {
        didSet {
            guard offersLogin, credentialID != oldValue, provider(of: credentialID) != provider(of: oldValue) else { return }
            modelName = ""
            effort = ""
        }
    }
    var strengthRank = 1
    var enabled: Bool

    private(set) var phase: Phase = .editing
    private(set) var nameLine: String?
    private(set) var failure: String?

    @ObservationIgnored private let api: any OwnerAPI
    @ObservationIgnored private let seat: Seat
    @ObservationIgnored private let allLogins: [ConnectAgentModel.LoginChoice]
    @ObservationIgnored private let onChanged: @MainActor () async -> Void
    @ObservationIgnored private var sent: (request: ChangeSeatRequest, key: IdempotencyKey)?

    init(
        api: any OwnerAPI, seat: Seat, logins: [ConnectAgentModel.LoginChoice],
        onChanged: @escaping @MainActor () async -> Void
    ) {
        self.api = api
        self.seat = seat
        self.allLogins = logins
        self.onChanged = onChanged
        name = seat.name
        modelName = seat.model ?? ""
        effort = seat.effort ?? ""
        credentialID = seat.credentialID
        enabled = seat.enabled
    }

    var title: String { AgentsCopy.changeTitle.filled(["name": seat.name]) }

    // MARK: what the form offers

    /// Only an agent the app runs has a login to change.
    var offersLogin: Bool { seat.credentialID != nil }

    /// The logins the agent can move to: a Gemini login is left out for a
    /// Reviewer, which the runner cannot do yet (CL-8).
    var loginChoices: [ConnectAgentModel.LoginChoice] {
        seat.role == .reviewer ? allLogins.filter { $0.provider != .gemini } : allLogins
    }

    var geminiHiddenForReviewer: Bool {
        seat.role == .reviewer && allLogins.contains { $0.provider == .gemini }
    }

    /// Effort is asked for only where the tool takes one.
    var offersEffort: Bool { ProviderCatalog.takesEffort(chosenProvider) }

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

    private static func setting(_ text: String, was: String?) -> Setting<String> {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard typed != (was ?? "") else { return .keep }
        return typed.isEmpty ? .clear : .set(typed)
    }

    /// The change, or nil when nothing differs or the form is not valid: an
    /// empty name, or a login that is not one of the choices.
    var request: ChangeSeatRequest? {
        guard !trimmedName.isEmpty else { return nil }
        var login: Setting<UUID> = .keep
        if offersLogin, credentialID != seat.credentialID {
            guard let chosen = credentialID, loginChoices.contains(where: { $0.id == chosen }) else { return nil }
            login = .set(chosen)
        }
        let request = ChangeSeatRequest(
            name: trimmedName != seat.name ? trimmedName : nil,
            model: Self.setting(modelName, was: seat.model),
            effort: offersEffort ? Self.setting(effort, was: seat.effort) : .keep,
            credentialID: login,
            enabled: enabled != seat.enabled ? enabled : nil)
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
