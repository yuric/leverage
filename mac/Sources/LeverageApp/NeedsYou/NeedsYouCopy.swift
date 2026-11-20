import Foundation

/// The owner-facing sentences of the Needs you screen (HM-24). This is the
/// first version, with the two sentences the placeholder view draws; WP14
/// writes the rest: one row per item kind, with its choices.
enum NeedsYouCopy: OwnerFacingCopy {
    case title, empty

    var text: String {
        switch self {
        case .title: "Needs you"
        case .empty: "Nothing needs you right now."
        }
    }
}
