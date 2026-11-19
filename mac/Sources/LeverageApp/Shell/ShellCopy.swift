/// The owner-facing sentences of this screen. A placeholder until the
/// screen is built.
enum ShellCopy: OwnerFacingCopy {
    case placeholder

    var text: String {
        switch self {
        case .placeholder: "leverage is getting ready."
        }
    }
}
