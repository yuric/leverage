/// The owner-facing sentences of this screen. A placeholder until the
/// screen is built.
enum TaskPageCopy: OwnerFacingCopy {
    case placeholder

    var text: String {
        switch self {
        case .placeholder: "The task page is on its way."
        }
    }
}
