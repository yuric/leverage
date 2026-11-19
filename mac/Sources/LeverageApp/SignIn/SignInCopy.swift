/// The owner-facing sentences of this screen. A placeholder until the
/// screen is built.
enum SignInCopy: OwnerFacingCopy {
    case placeholder

    var text: String {
        switch self {
        case .placeholder: "Signing in is on its way."
        }
    }
}
