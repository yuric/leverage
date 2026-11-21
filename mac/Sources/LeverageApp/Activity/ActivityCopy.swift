enum ActivityCopy: OwnerFacingCopy {
    case title, filter, important, everything, showEarlier, empty, loading
    case aTask, deletedTask, taskPrefix

    var text: String {
        switch self {
        case .title: "Activity"
        case .filter: "Activity filter"
        case .important: "Important"
        case .everything: "Everything"
        case .showEarlier: "Show earlier"
        case .empty: "No activity to show."
        case .loading: "Loading activity"
        case .aTask: "A task"
        case .deletedTask: "a deleted task"
        case .taskPrefix: "{title}:"
        }
    }
}
