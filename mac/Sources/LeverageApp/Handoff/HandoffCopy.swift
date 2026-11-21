import Foundation

/// The owner-facing sentences of the Handoff screen (HM-32 to HM-37). The eight
/// rules are the PRD's, word for word (L659 to L666): `HandoffCopyTests` reads
/// them from `docs/PRD.md` and compares. The mockup's fifth sentence, on where
/// a new login is placed, is not one of them and is not shown.
enum HandoffCopy: OwnerFacingCopy {
    case title, hint, rulesTitle, rulesHint
    case loading, empty
    case moveUp, moveDown, dropHint, orderChanged
    case handsOffTo, handsOffToNobody, notUsedForWorkYet
    case stateReady, stateWorking, stateSignedOut, stateLimit, stateLimitUntil
    case rule1, rule2, rule3, rule4, rule5, rule6, rule7, rule8

    var text: String {
        switch self {
        case .title: "Handoff order"
        case .hint: "When one reaches its limit, the next one down takes over."
        case .rulesTitle: "Rules"
        case .rulesHint: "Run by code, the same way every time."
        case .loading: "Loading the order…"
        case .empty: "No accounts yet. Add one in Credentials, and it appears here."
        case .moveUp: "Move up"
        case .moveDown: "Move down"
        case .dropHint: "Drop to make {account} number {number}."
        case .orderChanged: "The list changed. Try again."
        case .handsOffTo: "Hands off to {account}"
        case .handsOffToNobody: "Hands off to nobody"
        case .notUsedForWorkYet: "Not used for work yet"
        case .stateReady: "Ready"
        case .stateWorking: "Working"
        case .stateSignedOut: "Signed out"
        case .stateLimit: "At its limit"
        case .stateLimitUntil: "At its limit until {time}"
        case .rule1: "When an account reaches its limit, it rests until the reset time the provider gave."
        case .rule2: "Work moves to the next account below it in the order that is signed in and under its limit. Accounts above it are not tried."
        case .rule3: "An account found signed out is passed over, and work moves on in the same way."
        case .rule4: "Work may move to an account of any provider."
        case .rule5: "Moving on is always automatic, between two accounts of the same provider too. There is no switch for it."
        case .rule6: "An agent goes back to its own account for its next task once that account has reset."
        case .rule7: "Every piece of work records which account did it."
        case .rule8: "If no account below is free, the task waits. Its card says which account it is waiting for and when that account resets. If one of the accounts is signed out, the app asks you to sign in again."
        }
    }

    /// The eight sentences, in order.
    static let rules: [HandoffCopy] = [.rule1, .rule2, .rule3, .rule4, .rule5, .rule6, .rule7, .rule8]
}
