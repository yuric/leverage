import Foundation
import LeverageKit

/// What the Needs you rows and the notifications name: the task titles and the
/// accounts, from the board and the credentials reads. Never an email.
struct NeedsYouNames: Sendable {
    var tasks: [UUID: String] = [:]
    var credentials: [UUID: Credential] = [:]

    func taskTitle(_ id: UUID?) -> String { "" }
    func accountName(_ id: UUID?) -> String { "" }
    func provider(of id: UUID?) -> Provider? { nil }

    /// Reads the board and the credentials, in that order; the lower of their
    /// two positions is where the events tail starts.
    static func read(from owner: any OwnerAPI) async throws -> (names: NeedsYouNames, asOfSeq: Int) {
        (NeedsYouNames(), 0)
    }
}

/// One button of an item, with the command it sends.
struct NeedsYouButton: Identifiable, Equatable, Sendable {
    enum Action: String, Sendable { case signInAgain, allowAnotherTry, changeTask, cancelTask }

    let action: Action
    let label: String
    var id: Action { action }
}

/// The words of each item kind (HM-24), shared by the screen and the notifier.
enum NeedsYouWords {
    /// Whether the screen can open an item of this kind: every choice it
    /// offers has a route (HM-21).
    static func isShown(_ kind: NeedsYouItem) -> Bool { false }
    static func heading(for item: InboxItem, names: NeedsYouNames) -> String { "" }
    static func body(for item: InboxItem, names: NeedsYouNames) -> String { "" }
    static func buttons(for item: InboxItem) -> [NeedsYouButton] { [] }
    /// The heading of a notification sent from an event alone.
    static func settledHeading(kind: NeedsYouItem?) -> String { "" }
}
