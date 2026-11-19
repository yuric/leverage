/// The owner-facing sentences of this screen. A placeholder until the
/// screen is built.
enum BoardCopy: OwnerFacingCopy {
    case placeholder

    var text: String {
        switch self {
        case .placeholder: "The board is on its way."
        }
    }
}
