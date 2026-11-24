/// The owner-facing sentences of the setup assistant.
enum SetupAssistantCopy: OwnerFacingCopy {
    case welcomeTitle

    var text: String {
        switch self {
        case .welcomeTitle: "Welcome to Leverage"
        }
    }
}
