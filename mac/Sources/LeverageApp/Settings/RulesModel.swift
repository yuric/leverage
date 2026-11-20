import Foundation
import LeverageKit
import Observation

/// One rule as the Rules screen shows it, in the owner's words (RM-1).
struct RuleLine: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    let isOn: Bool
    /// "When a task is ready to start".
    let whenItRuns: String
    /// "Every task" or "The checker decides".
    let appliesTo: String
    /// "leverage checks this itself" or "An agent checks this".
    let checkedBy: String
    /// "Stop the task" or "Only note it" on a gate; nil on a policy.
    let ifItFails: String?
    /// An app rule's sentence, or a model rule's instruction.
    let detail: String
    let detailIsInstruction: Bool
    /// "Starts working in a later version of leverage" while its effect is not built.
    let notActing: String?
    /// "Ran 12 times · average 8 seconds · …".
    let counts: String
    /// "Wording of Nov 12, 2026".
    let wording: String
    let isShipped: Bool
    let row: RuleRow
}

/// Settings, Rules (RD-25): the rules in the order the server gives them,
/// each with its switch. It reads again after an event of a `rule.*` type
/// (RM-2); nothing polls.
@MainActor
@Observable
final class RulesModel {
    enum State: Equatable, Sendable {
        case loading
        case loaded
        case failed(ShellCopy)
        /// The sign-in ended. The shell returns the app to Sign in.
        case signedOut
    }

    private(set) var state: State = .loading
    private(set) var lines: [RuleLine] = []
    /// The sentence for a switch that did not work.
    private(set) var failure: ShellCopy?
    /// The rules whose switch is being sent.
    private(set) var changing: Set<UUID> = []

    @ObservationIgnored private let api: any OwnerAPI
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private let locale: Locale

    init(api: any OwnerAPI, calendar: Calendar = .current, locale: Locale = .current) {
        self.api = api
        self.calendar = calendar
        self.locale = locale
    }

    func load() async {}

    /// Turns a rule on or off, then reads the rules again.
    func setEnabled(_ id: UUID, to on: Bool) async {}

    /// Reads again after an event of a `rule.*` type.
    func attach(to feed: EventFeed) {}

    func detach() {}

    /// The line of each row.
    static func lines(for rows: [RuleRow], calendar: Calendar, locale: Locale) -> [RuleLine] { [] }
}
