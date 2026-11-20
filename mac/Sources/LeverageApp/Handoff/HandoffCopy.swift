import Foundation

/// The owner-facing sentences of the Handoff screen (HM-32 to HM-37).
enum HandoffCopy: OwnerFacingCopy {
    case title, hint, rulesTitle, rulesHint
    case loading, empty
    case handsOffTo, handsOffToNobody
    case stateReady, stateWorking, stateSignedOut, stateLimit, stateLimitUntil
    case rule1, rule2, rule3, rule4, rule5, rule6, rule7, rule8

    var text: String {
        switch self {
        case .title: "Handoff order"
        case .hint: "When one reaches its limit, the next one down takes over."
        case .rulesTitle: "Rules"
        case .rulesHint: "Run by code, the same way every time."
        case .loading: "Loading the order…"
        case .empty: "No logins yet. Add one in Credentials, and it appears here."
        case .handsOffTo: "Hands off to {account}"
        case .handsOffToNobody: "Hands off to nobody"
        case .stateReady: "Ready"
        case .stateWorking: "Working"
        case .stateSignedOut: "Signed out"
        case .stateLimit: "At its limit"
        case .stateLimitUntil: "At its limit until {time}"
        case .rule1, .rule2, .rule3, .rule4, .rule5, .rule6, .rule7, .rule8: "Not written yet."
        }
    }

    /// The eight sentences, in order.
    static let rules: [HandoffCopy] = [.rule1, .rule2, .rule3, .rule4, .rule5, .rule6, .rule7, .rule8]
}
