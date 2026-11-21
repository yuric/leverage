import Foundation
import LeverageKit
import Observation

/// A card's small state word on a toned background.
struct CardChip: Equatable, Sendable {
    let text: String
    let tone: Tokens.Tone
}

/// What a card knows about an account the task waits for: its name as the
/// owner reads it, whether it is signed out, and when its limit ends.
struct CardAccount: Equatable, Sendable {
    let name: String
    let isSignedOut: Bool
    let limitedUntil: Date?

    init(name: String, isSignedOut: Bool = false, limitedUntil: Date? = nil) {
        self.name = name
        self.isSignedOut = isSignedOut
        self.limitedUntil = limitedUntil
    }

    /// "Claude, Personal": the provider and the name, never the email.
    init(of credential: Credential) {
        self.init(
            name: "\(ProviderNames.name(credential.provider)), \(credential.name)",
            isSignedOut: credential.state == .signedOut, limitedUntil: credential.limitedUntil)
    }
}

/// What a card (and the top of a task page) says about a task, in plain words.
struct CardContent: Equatable, Sendable {
    let statusLine: String
    let chip: CardChip?
    let note: String?
}

/// The words of a card, from the task's state, its holds and the names of the
/// agents (MA-1, MA-28, MA-29). One home, used by the board and the task page.
enum CardWording {
    /// What a task waits for from an account: the sentence, and whether the
    /// account is signed out (a sign-in) rather than at a limit (a reset).
    private struct AccountWait {
        let note: String
        let signedOut: Bool
    }

    /// A task waits for an account when a hold of that kind is open, or the
    /// read names one (HM-40, HE-15, HE-16). The words are HM-45's.
    private static func accountWait(
        _ task: BoardTask, _ waits: [HoldReason], _ accounts: [UUID: CardAccount], _ clock: ResetClock
    ) -> AccountWait? {
        let limitHold = waits.contains(.credentialLimit)
        let signedOutHold = waits.contains(.credentialSignedOut)
        guard limitHold || signedOutHold || task.waitingForCredentialID != nil else { return nil }
        let account = task.waitingForCredentialID.flatMap { accounts[$0] }
        let name = account?.name ?? BoardCopy.anAccount.text
        // A signed-out account is waited for by a sign-in whatever the hold:
        // its reset alone would not make it available, and the read leaves
        // its reset time out (HE-11).
        if signedOutHold || account?.isSignedOut == true {
            let sentence = BoardCopy.noteAccountSignedOut.filled(["account": name])
            return AccountWait(note: sentence.prefix(1).uppercased() + sentence.dropFirst(), signedOut: true)
        }
        guard let until = task.waitingUntil ?? account?.limitedUntil else {
            return AccountWait(note: BoardCopy.noteWaitingForAccountNoTime.filled(["account": name]), signedOut: false)
        }
        let time = ResetTime.text(for: until, clock: clock)
        return AccountWait(
            note: BoardCopy.noteWaitingForAccount.filled(["account": name, "time": time]), signedOut: false)
    }

    static func content(
        for task: BoardTask, seatNames: [UUID: String], reviewerSeatExists: Bool,
        accounts: [UUID: CardAccount] = [:], clock: ResetClock = .system
    ) -> CardContent {
        let state = task.task.state
        let lane = BoardLane.lane(for: task)
        let agent = (task.task.holderSeatID ?? task.task.builderSeatID).flatMap { seatNames[$0] }
            ?? BoardCopy.anAgent.text
        let builder = task.task.builderSeatID.flatMap { seatNames[$0] } ?? BoardCopy.anAgent.text

        let line: String
        var chip: CardChip?
        switch state {
        case .imaginarium:
            line = BoardCopy.lineNotStarted.text
        case .backlog where task.checking:
            line = BoardCopy.lineCheckingDetails.text
            chip = CardChip(text: BoardCopy.chipCheckingDetails.text, tone: .info)
        case .backlog:
            line = BoardCopy.lineNeedsDetails.text
            chip = CardChip(text: BoardCopy.chipNeedsDetails.text, tone: .wait)
        case .ready:
            line = BoardCopy.lineWaitingForAgent.text
            chip = CardChip(text: BoardCopy.chipNew.text, tone: .info)
        case .working, .finishing:
            line = BoardCopy.lineBuilding.filled(["agent": agent])
        case .inReview:
            line = BoardCopy.lineReviewing.filled(["agent": builder])
            chip = CardChip(text: BoardCopy.chipInReview.text, tone: .info)
        case .done:
            line = BoardCopy.lineFinished.text
            chip = CardChip(text: BoardCopy.chipDone.text, tone: .done)
        case .cancelled:
            line = BoardCopy.lineCancelled.text
            chip = CardChip(text: BoardCopy.chipCancelled.text, tone: .plain)
        }

        var statusLine = line
        if lane == .blocked {
            let was = BoardLane.lane(forState: state).heading.text
            statusLine = BoardCopy.linePaused.filled(["lane": was])
        }

        // What the task waits on says more than its state does.
        let waits = state == .done || state == .cancelled ? [] : task.holdReasons
        let waitReason = waits.first(where: BoardLane.blockingReasons.contains)
            ?? waits.first(where: { BoardCopy.chip(for: $0) != nil })
        if let waitReason, let copy = BoardCopy.chip(for: waitReason) {
            let stops: Set<HoldReason> = [.roundsExceeded, .actionStopped, .checkError, .credentialSignedOut]
            chip = CardChip(text: copy.text, tone: stops.contains(waitReason) ? .stop : .wait)
        } else if task.checking, state != .backlog, state != .done, state != .cancelled {
            // A command of the task waits for its checks and nothing else holds it (RD-27).
            chip = CardChip(text: BoardCopy.chipBeingChecked.text, tone: .info)
        }

        var note: String?
        let accountWait = state == .done || state == .cancelled ? nil : accountWait(task, waits, accounts, clock)
        if let accountWait {
            note = accountWait.note
            // A Ready task no agent can start has no hold to give it a chip.
            if waitReason == nil, state == .ready {
                chip = CardChip(
                    text: (accountWait.signedOut ? BoardCopy.chipLoginSignedOut : BoardCopy.chipNoLoginLeft).text,
                    tone: accountWait.signedOut ? .stop : .wait)
            }
        } else if state == .inReview, !reviewerSeatExists {
            note = BoardCopy.noteNoReviewer.text
        }
        if note == nil {
            // A failed check leaves the card saying what it said, with the reason beside it (RD-27); a hold a
            // rule opened says what to do. The reason is text a model wrote: shown as it is, never acted on.
            if let reason = task.checkReason, !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                note = reason
            } else if let waitReason, let copy = BoardCopy.note(for: waitReason) {
                note = copy.text
            }
        }
        return CardContent(statusLine: statusLine, chip: chip, note: note)
    }
}

/// One card of the board.
struct BoardCard: Identifiable, Equatable, Sendable {
    let id: UUID
    let title: String
    let lane: BoardLane
    let statusLine: String
    let chip: CardChip?
    let note: String?

    init(
        task: BoardTask, seatNames: [UUID: String], reviewerSeatExists: Bool, accounts: [UUID: CardAccount] = [:],
        clock: ResetClock = .system
    ) {
        let content = CardWording.content(
            for: task, seatNames: seatNames, reviewerSeatExists: reviewerSeatExists, accounts: accounts, clock: clock)
        id = task.task.id
        title = task.task.title
        lane = BoardLane.lane(for: task)
        statusLine = content.statusLine
        chip = content.chip
        note = content.note
    }
}

/// The board: six lanes from `get_board`, with the names of the agents from
/// `list_seats` (MA-1, MA-20). It reads again whenever the events tail
/// delivers a batch; a read that fails keeps the cards already shown.
@MainActor
@Observable
final class BoardModel {
    enum State: Equatable, Sendable {
        case loading
        case loaded
        case failed(ShellCopy)
        /// The sign-in ended. The shell returns the app to Sign in.
        case signedOut
    }

    private(set) var state: State = .loading
    private(set) var cards: [BoardCard] = []
    /// The Show cancelled switch (MA-1).
    var showCancelled = false

    @ObservationIgnored private let api: any OwnerAPI
    @ObservationIgnored private let noteRead: @MainActor (Int) -> Void
    @ObservationIgnored private var seatNames: [UUID: String] = [:]
    @ObservationIgnored private var accounts: [UUID: CardAccount] = [:]
    @ObservationIgnored private var subscription: EventFeed.Subscription?
    @ObservationIgnored private var generation = 0

    @ObservationIgnored private let clock: ResetClock

    init(api: any OwnerAPI, noteRead: @escaping @MainActor (Int) -> Void, clock: ResetClock = .system) {
        self.api = api
        self.noteRead = noteRead
        self.clock = clock
    }

    /// The lanes as drawn: the six, and the cancelled lane while the switch is on.
    var lanes: [LaneContent] {
        let shown = showCancelled ? BoardLane.standard + [.cancelled] : BoardLane.standard
        return shown.map { lane in LaneContent(lane: lane, cards: cards.filter { $0.lane == lane }) }
    }

    /// Reads the board and the names of the agents.
    func load() async {
        generation += 1
        let mine = generation
        do {
            let board = try await api.board()
            var position = board.asOfSeq
            var names = seatNames
            do {
                let seats = try await api.seats()
                names = Dictionary(seats.seats.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
                position = min(position, seats.asOfSeq)
            } catch let error as TransportError where error.code == .unauthenticated {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // The names are a nicety: the board still shows without them.
            }
            var known = accounts
            if board.tasks.contains(where: { $0.waitingForCredentialID != nil }) {
                // The accounts are a nicety too: a card that waits for one still says so without its name.
                do {
                    let list = try await api.credentials()
                    known = Dictionary(
                        list.credentials.map { ($0.credential.id, CardAccount(of: $0.credential)) },
                        uniquingKeysWith: { first, _ in first })
                    position = min(position, list.asOfSeq)
                } catch let error as TransportError where error.code == .unauthenticated {
                    throw error
                } catch is CancellationError {
                    throw CancellationError()
                } catch {}
            }
            guard mine == generation else { return }
            seatNames = names
            accounts = known
            cards = board.tasks.map {
                BoardCard(
                    task: $0, seatNames: names, reviewerSeatExists: board.reviewerSeatExists, accounts: known,
                    clock: clock)
            }
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
