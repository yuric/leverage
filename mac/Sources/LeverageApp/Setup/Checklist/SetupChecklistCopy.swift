/// The owner-facing sentences of the setup checklist and its spotlight.
enum SetupChecklistCopy: OwnerFacingCopy {
    case title

    var text: String {
        switch self {
        case .title: "Get your first task done"
        }
    }
}
