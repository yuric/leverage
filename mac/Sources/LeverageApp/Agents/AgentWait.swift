import Foundation
import LeverageKit

/// The account a running agent is waiting for (HM-45): its own login and every
/// login below it in the handoff order are all unavailable (the candidates of
/// the handoff, §2.1).
enum AgentWait {
    /// The account to name, or nil when the agent is not waiting for one: it
    /// has no login of its own, or at least one candidate is free.
    ///
    /// A candidate that is signed out is named first, in order, because only
    /// the owner can bring it back; otherwise the limited candidate that
    /// resets first, one with no reset time last.
    static func account(for seat: Seat, in credentials: [Credential], at now: Date) -> Credential? {
        guard let ownID = seat.credentialID,
              let own = credentials.first(where: { $0.id == ownID && $0.kind == .login })
        else { return nil }
        let candidates = credentials
            .filter { $0.kind == .login && $0.position >= own.position }
            .sorted { $0.position < $1.position }
        guard !candidates.isEmpty, !candidates.contains(where: { $0.isAvailable(at: now) }) else { return nil }
        if let signedOut = candidates.first(where: { $0.state == .signedOut }) { return signedOut }
        return candidates.min { first, second in
            switch (first.limitedUntil, second.limitedUntil) {
            case (let a?, let b?): a != b ? a < b : first.position < second.position
            case (_?, nil): true
            case (nil, _?): false
            case (nil, nil): first.position < second.position
            }
        }
    }
}
