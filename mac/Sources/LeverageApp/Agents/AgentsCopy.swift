/// The owner-facing sentences of this screen. A placeholder until the
/// screen is built.
enum AgentsCopy: OwnerFacingCopy {
    case placeholder

    var text: String {
        switch self {
        case .placeholder: "The agents list is on its way."
        }
    }
}
