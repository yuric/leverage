import Foundation
import LeverageKit
import Observation

/// A card's small state word on a toned background.
struct CardChip: Equatable, Sendable {
    let text: String
    let tone: Tokens.Tone
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
    static func content(for task: BoardTask, seatNames: [UUID: String], reviewerSeatExists: Bool) -> CardContent {
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
        }

        var note: String?
        if waits.contains(.credentialLimit) || (task.waitingForCredentialID != nil && state != .done) {
            if let until = task.waitingUntil {
                let time = until.formatted(date: .abbreviated, time: .shortened)
                note = BoardCopy.noteWaitingForLoginAt.filled(["time": time])
            } else {
                note = BoardCopy.noteWaitingForLogin.text
            }
        } else if state == .inReview, !reviewerSeatExists {
            note = BoardCopy.noteNoReviewer.text
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

    init(task: BoardTask, seatNames: [UUID: String], reviewerSeatExists: Bool) {
        let content = CardWording.content(for: task, seatNames: seatNames, reviewerSeatExists: reviewerSeatExists)
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
    @ObservationIgnored private var subscription: EventFeed.Subscription?
    @ObservationIgnored private var generation = 0

    init(api: any OwnerAPI, noteRead: @escaping @MainActor (Int) -> Void) {
        self.api = api
        self.noteRead = noteRead
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
            guard mine == generation else { return }
            seatNames = names
            cards = board.tasks.map {
                BoardCard(task: $0, seatNames: names, reviewerSeatExists: board.reviewerSeatExists)
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
