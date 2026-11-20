/// The owner-facing sentences of the Settings screen, Rules (milestone 4
/// plan RM-1). A placeholder: `Copy.swift` lists it so that WP16 adds its
/// words without touching the list.
enum RulesCopy: OwnerFacingCopy {
    case title

    var text: String {
        switch self {
        case .title: "Rules"
        }
    }
}
