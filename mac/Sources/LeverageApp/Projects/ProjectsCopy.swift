enum ProjectsCopy: OwnerFacingCopy {
    case title, deletedProject

    var text: String {
        switch self {
        case .title: "Projects"
        case .deletedProject: "Deleted project"
        }
    }
}
