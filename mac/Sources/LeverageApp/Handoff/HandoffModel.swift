import Foundation
import LeverageKit
import Observation

/// One account on the Handoff tab (HM-34 to HM-36): its number, its name, its
/// state, and the account it hands off to. Never an email or a plan (L655).
struct HandoffRow: Identifiable, Equatable, Sendable {
    let id: UUID
    /// 1 to n, in order, whatever gaps the stored positions have.
    let number: Int
    /// "Claude, Personal"
    let name: String
    /// Ready, Working, "At its limit until <time>", "At its limit" or Signed out.
    let state: String
    let tone: Tokens.Tone
    /// "Hands off to Codex, Team", or on the last row "Hands off to nobody".
    let handsOff: String
}

/// The Handoff tab: every account in the one handoff order, from
/// `list_credentials` in `position` order, each with its state. The tab only
/// reads; reordering is a later milestone's, and nothing here says it can be
/// changed (HM-37). It reads again each time the events tail delivers a batch.
///
/// Working is an agent whose run is on that account (`run_credential_id`);
/// without the agents the accounts still show, all Ready.
@MainActor
@Observable
final class HandoffModel {
    enum State: Equatable, Sendable {
        case loading
        case loaded
        case failed(ShellCopy)
        /// The sign-in ended. The shell returns the app to Sign in.
        case signedOut
    }

    private(set) var state: State = .loading
    private(set) var rows: [HandoffRow] = []

    @ObservationIgnored private let api: any OwnerAPI
    @ObservationIgnored private let noteRead: @MainActor (Int) -> Void
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private let locale: Locale
    @ObservationIgnored private var subscription: EventFeed.Subscription?
    @ObservationIgnored private var generation = 0

    init(
        api: any OwnerAPI, noteRead: @escaping @MainActor (Int) -> Void, now: @escaping () -> Date = Date.init,
        calendar: Calendar = .current, locale: Locale = .current
    ) {
        self.api = api
        self.noteRead = noteRead
        self.now = now
        self.calendar = calendar
        self.locale = locale
    }

    func load() async {
        generation += 1
        let mine = generation
        do {
            let list = try await api.credentials()
            var position = list.asOfSeq
            var working: Set<UUID> = []
            do {
                let seats = try await api.seats()
                working = Set(
                    seats.seats.filter { $0.removedAt == nil && $0.runState == .running }.compactMap(\.runCredentialID))
                position = min(position, seats.asOfSeq)
            } catch let error as TransportError where error.code == .unauthenticated {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch {}
            guard mine == generation else { return }
            rows = Self.rows(of: list.credentials.map(\.credential), working: working, at: now(), calendar: calendar, locale: locale)
            state = .loaded
            noteRead(position)
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

    /// The rows of the order: numbered 1 to n in position order, each naming
    /// the account below it.
    static func rows(
        of credentials: [Credential], working: Set<UUID>, at now: Date, calendar: Calendar, locale: Locale
    ) -> [HandoffRow] {
        let ordered = credentials.sorted { $0.position < $1.position }
        let clock = ResetClock(now: { now }, calendar: calendar, locale: locale)
        return ordered.enumerated().map { index, credential in
            let (state, tone) = stateWords(of: credential, working: working.contains(credential.id), at: now, clock: clock)
            let next = ordered.indices.contains(index + 1) ? ordered[index + 1] : nil
            return HandoffRow(
                id: credential.id, number: index + 1, name: ProviderNames.account(credential), state: state, tone: tone,
                handsOff: next.map { HandoffCopy.handsOffTo.filled(["account": ProviderNames.account($0)]) }
                    ?? HandoffCopy.handsOffToNobody.text)
        }
    }

    private static func stateWords(
        of credential: Credential, working: Bool, at now: Date, clock: ResetClock
    ) -> (String, Tokens.Tone) {
        if credential.state == .signedOut { return (HandoffCopy.stateSignedOut.text, .stop) }
        if credential.isLimited(at: now) {
            guard let until = credential.limitedUntil else { return (HandoffCopy.stateLimit.text, .stop) }
            return (HandoffCopy.stateLimitUntil.filled(["time": ResetTime.text(for: until, clock: clock)]), .stop)
        }
        return working ? (HandoffCopy.stateWorking.text, .done) : (HandoffCopy.stateReady.text, .info)
    }

    /// Reads again each time the events tail delivers a batch.
    func attach(to feed: EventFeed) {
        subscription?.cancel()
        subscription = feed.subscribe { [weak self] _ in
            Task { await self?.load() }
        }
    }

    func detach() {
        subscription?.cancel()
        subscription = nil
    }
}
