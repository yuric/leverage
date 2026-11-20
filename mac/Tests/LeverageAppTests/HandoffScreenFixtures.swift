import Foundation
import LeverageKit

@testable import LeverageApp

/// Made-up accounts for the Agents, Credentials and Handoff tests of the
/// Handoff milestone. Additive to `AgentFixtures`, whose helper does not know
/// `limited_since`.
extension AgentFixtures {
    /// Obviously not a real address; the tests check it is never shown.
    static let madeUpEmail = "someone@example.invalid"
    static let madeUpPlan = "Max (made up)"

    /// A fixed calendar and locale, so a time of day reads the same on every machine.
    static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    static let usEnglish = Locale(identifier: "en_US")

    /// A credential with every field the handoff screens read. `since` is when
    /// a limit was reported and `until` when it ends; a limit is `since` set
    /// with `until` empty or later than now (HE-3).
    static func account(
        _ id: UUID, name: String, provider: Provider = .claude, kind: CredentialKind = .login,
        state: CredentialState = .active, since: Date? = nil, until: Date? = nil, position: Int,
        email: String? = nil, plan: String? = nil
    ) -> CredentialWithReading {
        CredentialWithReading(
            credential: Credential(
                id: id, kind: kind, provider: provider, name: name, maskedLabel: kind == .apiToken ? "…abcd" : nil,
                plan: plan, accountEmail: email, state: state, limitedUntil: until, limitedSince: since,
                position: position))
    }

    /// A seat whose run is on a login (HD-3).
    static func runningSeat(
        _ id: UUID, name: String, provider: Provider = .claude, credential: UUID, runOn: UUID? = nil,
        role: SeatRole = .builder, enabled: Bool = true, paused: Bool = false
    ) -> Seat {
        Seat(
            id: id, name: name, provider: provider, role: role, strengthRank: 1, credentialID: credential,
            enabled: enabled, paused: paused, runState: .running, runCredentialID: runOn ?? credential)
    }
}
