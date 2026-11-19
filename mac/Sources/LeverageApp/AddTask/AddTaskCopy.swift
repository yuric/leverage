/// The owner-facing sentences of this screen. A placeholder until the
/// screen is built.
enum AddTaskCopy: OwnerFacingCopy {
    case placeholder

    var text: String {
        switch self {
        case .placeholder: "Adding a task is on its way."
        }
    }
}
