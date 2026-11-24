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
    /// The login's availability or the token's "Not used for work yet".
    let state: String
    let tone: Tokens.Tone
    /// The next login for a login, or why the token stays in the order.
    let handsOff: String
}

struct HandoffDropPreview: Equatable {
    let sourceID: UUID
    let targetID: UUID
    let above: Bool
    let hint: String
}

/// The Handoff tab loads the server's order and shows moves immediately
/// while it saves the full order. The event tail keeps the rows current.
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
    private(set) var dropPreview: HandoffDropPreview?
    private(set) var reorderFailure: String?

    private var isReordering = false

    @ObservationIgnored private let api: any OwnerAPI
    @ObservationIgnored private let noteRead: @MainActor (Int) -> Void
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private let locale: Locale
    @ObservationIgnored private var subscription: EventFeed.Subscription?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var isReading = false
    @ObservationIgnored private var refreshAfterReorder = false
    @ObservationIgnored private var credentials: [Credential] = []
    @ObservationIgnored private var working: Set<UUID> = []
    @ObservationIgnored private var unanswered: (order: [UUID], key: IdempotencyKey)?

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
        if isReordering {
            refreshAfterReorder = true
            return
        }

        generation += 1
        let mine = generation
        isReading = true
        defer { if mine == generation { isReading = false } }
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
            credentials = list.credentials.map(\.credential).sorted { $0.position < $1.position }
            self.working = working
            updateRows()
            state = .loaded
            if let preview = dropPreview { previewDrop(of: preview.sourceID, over: preview.targetID) }
            noteRead(position)
        } catch is CancellationError {
            return
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch let error as TransportError where error.code == .unauthenticated {
            if mine == generation {
                state = .signedOut
                dropPreview = nil
            }
        } catch {
            if mine == generation {
                state = .failed(ShellCopy.sentence(for: error))
                dropPreview = nil
            }
        }
    }

    func canMoveUp(_ id: UUID) -> Bool { adjacent(to: id, offset: -1) != nil }
    func canMoveDown(_ id: UUID) -> Bool { adjacent(to: id, offset: 1) != nil }

    func moveUp(_ id: UUID) async {
        if let target = adjacent(to: id, offset: -1) { await drop(id, over: target) }
    }

    func moveDown(_ id: UUID) async {
        if let target = adjacent(to: id, offset: 1) { await drop(id, over: target) }
    }

    func previewDrop(of id: UUID, over targetID: UUID) {
        guard let move = moveIndices(of: id, over: targetID) else {
            dropPreview = nil
            return
        }
        dropPreview = HandoffDropPreview(
            sourceID: id, targetID: targetID, above: move.from > move.to,
            hint: HandoffCopy.dropHint.filled(["account": rows[move.from].name, "number": String(move.to + 1)]))
    }

    func clearDropPreview(over targetID: UUID) {
        if dropPreview?.targetID == targetID { dropPreview = nil }
    }

    func drop(_ id: UUID, over targetID: UUID) async {
        dropPreview = nil
        guard let move = moveIndices(of: id, over: targetID) else { return }
        let previous = credentials
        let previousRows = rows

        // A read started before the move cannot replace its optimistic order.
        refreshAfterReorder = isReading
        isReading = false
        generation += 1
        isReordering = true
        reorderFailure = nil
        let credential = credentials.remove(at: move.from)
        credentials.insert(credential, at: move.to)
        updateRows()

        let order = credentials.map(\.id)
        let key = unanswered.flatMap { $0.order == order ? $0.key : nil } ?? IdempotencyKey()
        unanswered = (order, key)
        do {
            let outcome = try await api.reorderCredentials(ReorderCredentialsRequest(order: order), key: key)
            _ = try outcome.completedResult()
            unanswered = nil
        } catch {
            credentials = previous
            rows = previousRows
            if CommandKey.wasAnswered(error) { unanswered = nil }
            if (error as? TransportError)?.code == .unauthenticated {
                state = .signedOut
                refreshAfterReorder = false
            } else {
                refreshAfterReorder = true
                if (error as? TransportError)?.status == 422 {
                    reorderFailure = HandoffCopy.orderChanged.text
                } else if !(error is CancellationError), (error as? URLError)?.code != .cancelled {
                    reorderFailure = ShellCopy.sentence(for: error).text
                }
            }
        }

        isReordering = false
        if refreshAfterReorder {
            refreshAfterReorder = false
            await load()
        }
    }

    private func adjacent(to id: UUID, offset: Int) -> UUID? {
        guard state == .loaded, !isReordering, let index = rows.firstIndex(where: { $0.id == id }),
              rows.indices.contains(index + offset) else { return nil }
        return rows[index + offset].id
    }

    private func moveIndices(of id: UUID, over targetID: UUID) -> (from: Int, to: Int)? {
        guard state == .loaded, !isReordering, id != targetID,
              let from = rows.firstIndex(where: { $0.id == id }),
              let to = rows.firstIndex(where: { $0.id == targetID }) else { return nil }
        return (from, to)
    }

    private func updateRows() {
        let at = now()
        let clock = ResetClock(now: { at }, calendar: calendar, locale: locale)
        var nextLogin: String?
        var fromLast: [HandoffRow] = []
        for (index, credential) in credentials.enumerated().reversed() {
            let name = ProviderNames.account(credential)
            let state: String
            let tone: Tokens.Tone
            let handsOff: String
            if credential.kind == .apiToken {
                state = HandoffCopy.notUsedForWorkYet.text
                tone = .plain
                handsOff = state
            } else {
                (state, tone) = Self.stateWords(of: credential, working: working.contains(credential.id), at: at, clock: clock)
                handsOff = nextLogin.map { HandoffCopy.handsOffTo.filled(["account": $0]) } ?? HandoffCopy.handsOffToNobody.text
                nextLogin = name
            }
            fromLast.append(HandoffRow(
                id: credential.id, number: index + 1, name: name, state: state, tone: tone, handsOff: handsOff))
        }
        rows = Array(fromLast.reversed())
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
        dropPreview = nil
    }
}
