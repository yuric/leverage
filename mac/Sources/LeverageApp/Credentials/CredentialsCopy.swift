/// The owner-facing sentences of this screen. A placeholder until the
/// screen is built.
enum CredentialsCopy: OwnerFacingCopy {
    case placeholder

    var text: String {
        switch self {
        case .placeholder: "The logins list is on its way."
        }
    }
}
