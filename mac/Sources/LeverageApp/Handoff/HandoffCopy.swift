import Foundation

/// The owner-facing sentences of the Handoff screen (HM-32). This is the
/// first version, with the two sentences the placeholder view draws; WP16
/// writes the rest: the PRD's eight sentences, word for word.
enum HandoffCopy: OwnerFacingCopy {
    case title, hint

    var text: String {
        switch self {
        case .title: "Handoff order"
        case .hint: "When one reaches its limit, the next one down takes over."
        }
    }
}
