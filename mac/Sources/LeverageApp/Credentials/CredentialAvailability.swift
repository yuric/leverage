import Foundation
import LeverageKit

extension Credential {
    /// A limit was reported and its reset time has not passed, or the provider
    /// gave none (HE-3). A reset time with no report of a limit is not one,
    /// and a time that has passed ends it: nothing is written when it does.
    func isLimited(at now: Date) -> Bool {
        guard limitedSince != nil else { return false }
        guard let limitedUntil else { return true }
        return limitedUntil > now
    }

    /// Signed in and not limited: work can go to it (rule 2 of the handoff).
    func isAvailable(at now: Date) -> Bool {
        state == .active && !isLimited(at: now)
    }
}
