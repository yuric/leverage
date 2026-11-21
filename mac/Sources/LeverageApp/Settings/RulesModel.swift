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
    @ObservationIgnored private var subscription: EventFeed.Subscription?
    @ObservationIgnored private var generation = 0

    init(api: any OwnerAPI, calendar: Calendar = .current, locale: Locale = .current) {
        self.api = api
        self.calendar = calendar
        self.locale = locale
    }

    func load() async {
        generation += 1
        let mine = generation
        do {
            let list = try await api.listRules()
            guard mine == generation else { return }
            lines = Self.lines(for: list.rules, calendar: calendar, locale: locale)
            state = .loaded
        } catch is CancellationError {
            return
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch let error as TransportError where error.code == .unauthenticated {
            if mine == generation { state = .signedOut }
        } catch {
            if mine == generation { state = .failed(ShellCopy.sentence(for: error)) }
        }
    }

    /// Turns a rule on or off, then reads the rules again, so the screen shows
    /// what the server says whether or not the switch worked.
    func setEnabled(_ id: UUID, to on: Bool) async {
        guard !changing.contains(id) else { return }
        changing.insert(id)
        failure = nil
        do {
            let key = IdempotencyKey()
            let outcome = on ? try await api.enableRule(ruleID: id, key: key)
                : try await api.disableRule(ruleID: id, key: key)
            _ = try outcome.completedResult()
        } catch is CancellationError {
            changing.remove(id)
            return
        } catch {
            failure = ShellCopy.sentence(for: error)
        }
        changing.remove(id)
        await load()
    }

    /// Reads again after an event of a `rule.*` type (RM-2).
    func attach(to feed: EventFeed) {
        subscription?.cancel()
        subscription = feed.subscribe { [weak self] events in
            guard events.contains(where: { $0.type.rawValue.hasPrefix("rule.") }) else { return }
            Task { await self?.load() }
        }
    }

    func detach() {
        subscription?.cancel()
        subscription = nil
    }

    // MARK: the words of a row

    /// The line of each row, in the order given.
    static func lines(for rows: [RuleRow], calendar: Calendar, locale: Locale) -> [RuleLine] {
        rows.map { line(for: $0, calendar: calendar, locale: locale) }
    }

    private static func line(for row: RuleRow, calendar: Calendar, locale: Locale) -> RuleLine {
        let version = row.version
        let model = version.checker == .model
        return RuleLine(
            id: row.rule.id, name: version.name, isOn: row.rule.enabled, whenItRuns: capitalized(row.momentName),
            appliesTo: RulesCopy.scopeWords(version.scope.kind).text, checkedBy: (model ? RulesCopy.checkerModel : .checkerApp).text,
            ifItFails: version.onFail.map { ($0 == .block ? RulesCopy.onFailBlock : .onFailWarn).text },
            detail: (model ? version.instruction : row.sentence) ?? "", detailIsInstruction: model,
            notActing: row.acts ? nil : RulesCopy.notActing.text,
            counts: counts(of: row.stats, model: model, locale: locale),
            wording: RulesCopy.wordingOf.filled(["date": date(version.createdAt, calendar: calendar, locale: locale)]),
            isShipped: version.origin == .shipped, row: row)
    }

    private static func capitalized(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst()
    }

    private static func date(_ date: Date, calendar: Calendar, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    /// How a rule has run (RD-26): how often, the average time, tokens, the
    /// spend the tools reported (RD-32) and how often it was let through.
    /// Tokens and spend are always there for a rule an agent checks that has
    /// run, and for an app rule only when it has some.
    private static func counts(of stats: RuleStats, model: Bool, locale: Locale) -> String {
        if stats.checks == 0, stats.tokens == 0, stats.spend == 0, stats.overrides == 0 {
            return RulesCopy.countsNone.text
        }
        var pieces: [String] = []
        if stats.checks == 1 {
            pieces.append(RulesCopy.countsRanOnce.text)
        } else if stats.checks > 1 {
            pieces.append(RulesCopy.countsRan.filled(["count": number(stats.checks, locale: locale)]))
        }
        if stats.checks > 0, let average = stats.averageSeconds {
            let time = average < 1 ? RulesCopy.countsUnderSecond.text : DurationWords.text(seconds: Int(average.rounded()))
            pieces.append(RulesCopy.countsAverage.filled(["time": time]))
        }
        if stats.tokens > 0 || (model && stats.checks > 0) {
            pieces.append(RulesCopy.countsTokens.filled(["count": number(stats.tokens, locale: locale)]))
        }
        if stats.spend > 0 || (model && stats.checks > 0) {
            pieces.append(RulesCopy.countsSpend.filled(["amount": dollars(stats.spend, locale: locale)]))
        }
        if stats.overrides == 1 {
            pieces.append(RulesCopy.countsLetThroughOnce.text)
        } else if stats.overrides > 1 {
            pieces.append(RulesCopy.countsLetThrough.filled(["count": number(stats.overrides, locale: locale)]))
        }
        return pieces.joined(separator: " · ")
    }

    private static func number(_ value: Int, locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    private static func dollars(_ value: Decimal, locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        return formatter.string(from: value as NSDecimalNumber) ?? "$\(value)"
    }
}
