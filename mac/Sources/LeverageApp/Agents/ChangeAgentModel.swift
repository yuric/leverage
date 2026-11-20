import Foundation
import LeverageKit
import Observation

/// The Change sheet of an agent (HM-51, HE-27). Empty until WP16's code
/// commit fills it in.
@MainActor
@Observable
final class ChangeAgentModel {
    enum Phase: Equatable, Sendable {
        case editing
        case saving
        case done
    }

    var name: String
    var modelName = ""
    var effort = ""
    var credentialID: UUID?
    var enabled: Bool
    private(set) var phase: Phase = .editing
    private(set) var nameLine: String?
    private(set) var failure: String?

    init(
        api: any OwnerAPI, seat: Seat, logins: [ConnectAgentModel.LoginChoice],
        onChanged: @escaping @MainActor () -> Void
    ) {
        name = seat.name
        enabled = seat.enabled
    }

    var title: String { "" }
    var offersLogin: Bool { false }
    var offersEffort: Bool { false }
    var loginChoices: [ConnectAgentModel.LoginChoice] { [] }
    var geminiHiddenForReviewer: Bool { false }
    var enabledNote: String? { nil }
    var request: ChangeSeatRequest? { nil }
    var canSave: Bool { false }

    func save() async {}
}
