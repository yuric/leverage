import Foundation
import LeverageKit
import LeverageTestSupport
import SwiftUI
import Testing

@testable import LeverageApp

private typealias Fixtures = TaskScreenFixtures

@MainActor
@Suite("BoardModel")
struct BoardModelTests {
    private func makeModel(_ owner: FakeOwnerAPI, reads: Locked<[Int]> = Locked([])) -> BoardModel {
        BoardModel(api: owner, noteRead: { seq in reads.update { $0.append(seq) } })
    }

    private func titles(_ model: BoardModel, in lane: BoardLane) -> [String] {
        model.lanes.first { $0.lane == lane }?.cards.map(\.title) ?? []
    }

    // MARK: loading, empty, loaded

    @Test("before the first read it says it is loading and shows six empty lanes")
    func loadingFirst() {
        let model = makeModel(FakeOwnerAPI())
        #expect(model.state == .loading)
        #expect(model.lanes.map(\.lane) == BoardLane.standard)
        #expect(model.lanes.allSatisfy { $0.cards.isEmpty })
    }

    @Test("an empty board is six empty lanes in the mockup's order")
    func emptyBoard() async {
        let model = makeModel(Fixtures.owner(board: Fixtures.board([])))
        await model.load()
        #expect(model.state == .loaded)
        #expect(model.lanes.map(\.lane) == [.imaginarium, .backlog, .blocked, .ready, .inProgress, .done])
        #expect(model.lanes.map(\.count) == [0, 0, 0, 0, 0, 0])
    }

    @Test("a read puts each task in its lane with its title, and counts them")
    func loadedLanes() async {
        let tasks = [
            Fixtures.boardTask(.backlog, title: "Draft the invoice copy"),
            Fixtures.boardTask(.ready, title: "Fix the totals"),
            Fixtures.boardTask(.ready, title: "Rename the report"),
            Fixtures.boardTask(.working, title: "Add the export", holder: Fixtures.builderID, builder: Fixtures.builderID),
            Fixtures.boardTask(.done, title: "Update the footer"),
            Fixtures.boardTask(.working, title: "Waiting on you", holds: [.ownerApproval]),
        ]
        let model = makeModel(Fixtures.owner(board: Fixtures.board(tasks)))
        await model.load()

        #expect(titles(model, in: .backlog) == ["Draft the invoice copy"])
        #expect(titles(model, in: .ready) == ["Fix the totals", "Rename the report"])
        #expect(titles(model, in: .inProgress) == ["Add the export"])
        #expect(titles(model, in: .done) == ["Update the footer"])
        #expect(titles(model, in: .blocked) == ["Waiting on you"])
        #expect(model.lanes.first { $0.lane == .ready }?.count == 2)
    }

    @Test("a read asks for the board and for the names of the agents, and tells the feed where it stood")
    func readsAndNotesPosition() async {
        let reads = Locked<[Int]>([])
        let owner = Fixtures.owner(board: Fixtures.board([], asOfSeq: 12), seats: Fixtures.seats(asOfSeq: 9))
        let model = makeModel(owner, reads: reads)
        await model.load()
        #expect(owner.calls.map(\.operation) == [.getBoard, .listSeats])
        // The lower position of the two reads, so no event after either is missed.
        #expect(reads.value == [9])
    }

    @Test("a card carries the task's id so a click can open its page")
    func cardIDs() async {
        let id = UUID()
        let model = makeModel(Fixtures.owner(board: Fixtures.board([Fixtures.boardTask(.ready, id: id)])))
        await model.load()
        #expect(model.lanes.flatMap(\.cards).map(\.id) == [id])
    }

    // MARK: Show cancelled

    @Test("cancelled tasks are hidden until the Show cancelled switch is on, and then show in their own lane")
    func showCancelled() async {
        let tasks = [Fixtures.boardTask(.ready, title: "Keep"), Fixtures.boardTask(.cancelled, title: "Dropped")]
        let model = makeModel(Fixtures.owner(board: Fixtures.board(tasks)))
        await model.load()
        #expect(!model.showCancelled)
        #expect(model.lanes.map(\.lane) == BoardLane.standard)
        #expect(model.lanes.flatMap(\.cards).map(\.title) == ["Keep"])

        model.showCancelled = true
        #expect(model.lanes.map(\.lane) == BoardLane.standard + [.cancelled])
        #expect(titles(model, in: .cancelled) == ["Dropped"])

        model.showCancelled = false
        #expect(model.lanes.flatMap(\.cards).map(\.title) == ["Keep"])
    }

    // MARK: failures

    @Test("a server that cannot be reached is a plain line, and the cards already shown stay")
    func cannotReach() async {
        let owner = Fixtures.owner(board: Fixtures.board([Fixtures.boardTask(.ready, title: "Stays")]))
        let model = makeModel(owner)
        await model.load()
        owner.script { $0.board = { throw URLError(.cannotConnectToHost) } }
        await model.load()
        #expect(model.state == .failed(.cannotReach))
        #expect(titles(model, in: .ready) == ["Stays"])

        owner.script { $0.board = { Fixtures.board([Fixtures.boardTask(.ready, title: "Back")]) } }
        await model.load()
        #expect(model.state == .loaded)
        #expect(titles(model, in: .ready) == ["Back"])
    }

    @Test("a sign-in that ended is its own state")
    func signedOut() async {
        let owner = FakeOwnerAPI()
        owner.script { $0.board = { throw TransportError(code: .unauthenticated, message: "no") } }
        let model = makeModel(owner)
        await model.load()
        #expect(model.state == .signedOut)
    }

    @Test("any other failure is the general line")
    func otherFailure() async {
        let owner = FakeOwnerAPI()
        owner.script { $0.board = { throw LeverageClientError.invalidBody } }
        let model = makeModel(owner)
        await model.load()
        #expect(model.state == .failed(.somethingWentWrong))
    }

    @Test("when the names of the agents cannot be read the board still shows, with a general name for them")
    func namesFailing() async {
        let owner = FakeOwnerAPI()
        let working = Fixtures.boardTask(.working, holder: Fixtures.builderID, builder: Fixtures.builderID)
        owner.script {
            $0.board = { Fixtures.board([working]) }
            $0.seats = { throw URLError(.timedOut) }
        }
        let model = makeModel(owner)
        await model.load()
        #expect(model.state == .loaded)
        #expect(model.lanes.flatMap(\.cards).first?.statusLine == "An agent is building")
    }

    // MARK: card wording

    private func card(_ task: BoardTask, reviewer: Bool = true) async -> BoardCard? {
        let model = makeModel(Fixtures.owner(board: Fixtures.board([task], reviewer: reviewer)))
        await model.load()
        return model.lanes.flatMap(\.cards).first
    }

    @Test("Ideas and Backlog cards say what is missing, in the mockup's words")
    func earlyCards() async {
        let idea = await card(Fixtures.boardTask(.imaginarium))
        #expect(idea?.statusLine == "Not started yet")
        #expect(idea?.chip == nil)
        let backlog = await card(Fixtures.boardTask(.backlog))
        #expect(backlog?.statusLine == "Say what done looks like to send it to an agent")
        #expect(backlog?.chip?.text == "Needs details")
    }

    @Test("a Ready card waits for a free agent and is marked New")
    func readyCard() async {
        let ready = await card(Fixtures.boardTask(.ready))
        #expect(ready?.statusLine == "Waiting for a free agent")
        #expect(ready?.chip?.text == "New")
    }

    @Test("a card in progress names the agent that is building it, or in review whose work is being checked")
    func progressCards() async {
        let building = await card(
            Fixtures.boardTask(.working, holder: Fixtures.builderID, builder: Fixtures.builderID))
        #expect(building?.statusLine == "Builder One is building")
        let reviewing = await card(Fixtures.boardTask(.inReview, builder: Fixtures.builderID))
        #expect(reviewing?.statusLine == "Builder One's work is being reviewed")
        #expect(reviewing?.chip?.text == "In review")
        let unknown = await card(Fixtures.boardTask(.working, holder: UUID(), builder: UUID()))
        #expect(unknown?.statusLine == "An agent is building")
    }

    @Test("a Done card says it was reviewed and finished, and a cancelled one that it was cancelled")
    func endCards() async {
        let done = await card(Fixtures.boardTask(.done))
        #expect(done?.statusLine == "Reviewed and finished")
        #expect(done?.chip?.text == "Done")
        let model = makeModel(Fixtures.owner(board: Fixtures.board([Fixtures.boardTask(.cancelled)])))
        await model.load()
        model.showCancelled = true
        #expect(model.lanes.flatMap(\.cards).first?.statusLine == "Cancelled")
    }

    @Test("a Blocked card says it is paused and which lane it was in, with the reason as a chip")
    func blockedCards() async {
        let working = await card(Fixtures.boardTask(.working, holds: [.ownerApproval]))
        #expect(working?.statusLine == "Paused, was In progress")
        #expect(working?.chip?.text == "Needs approval")
        let ready = await card(Fixtures.boardTask(.ready, holds: [.ownerQuestion]))
        #expect(ready?.statusLine == "Paused, was Ready")
        let rounds = await card(Fixtures.boardTask(.working, holds: [.roundsExceeded]))
        #expect(rounds?.statusLine == "Paused, was In progress")
        #expect(rounds?.chip?.text == "Sent back 3 times")
    }

    @Test("a task waiting for a login to reset says so, and when")
    func waitingForLogin() async {
        let until = Date(timeIntervalSince1970: 1_780_003_600)
        let waiting = await card(
            Fixtures.boardTask(.working, holds: [.credentialLimit], waitingFor: UUID(), waitingUntil: until))
        #expect(waiting?.chip?.text == "No login left")
        #expect(waiting?.note?.hasPrefix("Waiting for a login to reset") == true)
    }

    @Test("a task in review with no reviewer agent connected says so on its card, and only then")
    func noReviewerNote() async {
        let without = await card(Fixtures.boardTask(.inReview, builder: Fixtures.builderID), reviewer: false)
        #expect(without?.note == "No reviewer agent is connected. Connect one in Agents.")
        let with = await card(Fixtures.boardTask(.inReview, builder: Fixtures.builderID), reviewer: true)
        #expect(with?.note == nil)
        let ready = await card(Fixtures.boardTask(.ready), reviewer: false)
        #expect(ready?.note == nil)
    }

    @Test("no card uses a word the plain-language rule bans")
    func cardsAreInPlainWords() async {
        let tasks = TaskState.allCases.flatMap { state in
            [Fixtures.boardTask(state, holder: Fixtures.builderID, builder: Fixtures.builderID)]
                + HoldReason.allCases.map {
                    Fixtures.boardTask(state, holder: Fixtures.builderID, builder: Fixtures.builderID, holds: [$0])
                }
        }
        let model = makeModel(Fixtures.owner(board: Fixtures.board(tasks, reviewer: false)))
        await model.load()
        model.showCancelled = true
        let cards = model.lanes.flatMap(\.cards)
        #expect(cards.count == tasks.count)
        for card in cards {
            for text in [card.statusLine, card.chip?.text, card.note].compactMap({ $0 }) {
                #expect(BannedTerms.found(in: text).isEmpty, "\(text)")
                #expect(!text.contains("_") && !text.contains("{"), "\(text)")
            }
        }
    }

    // MARK: staying current

    @Test("it reads again when the events tail delivers a batch")
    func readsAgainOnEvents() async {
        let owner = Fixtures.owner(board: Fixtures.board([Fixtures.boardTask(.ready, title: "One")], asOfSeq: 5))
        let batches = Locked<[EventsPage]>([])
        owner.script {
            $0.events = { _, _, _ in
                while true {
                    if let page = batches.update({ $0.isEmpty ? nil : $0.removeFirst() }) { return page }
                    try await Task.sleep(for: .milliseconds(2))
                }
            }
        }
        let feed = EventFeed(owner: owner, waitSeconds: 25, retryDelay: .milliseconds(5))
        let model = BoardModel(api: owner, noteRead: { feed.noteRead(asOfSeq: $0) })
        model.attach(to: feed)
        await model.load()
        #expect(titles(model, in: .ready) == ["One"])

        owner.script { $0.board = { Fixtures.board([Fixtures.boardTask(.ready, title: "One"), Fixtures.boardTask(.ready, title: "Two")], asOfSeq: 6) } }
        batches.update { $0.append(EventsPage(events: [ShellFixtures.event(seq: 6)], nextAfterSeq: 6)) }

        #expect(await ShellFixtures.eventually { titles(model, in: .ready) == ["One", "Two"] })
        model.detach()
        feed.stop()
    }
}

@MainActor
@Suite("Board render")
struct BoardRenderTests {
    private func draws(_ view: some View) -> Bool {
        let renderer = ImageRenderer(content: view.frame(width: 900, height: 620))
        renderer.scale = 1
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff), let data = bitmap.bitmapData
        else { return false }
        let pixel = max(1, bitmap.bitsPerPixel / 8)
        for row in 0..<bitmap.pixelsHigh {
            let line = data + row * bitmap.bytesPerRow
            for column in 0..<bitmap.pixelsWide {
                let at = line + column * pixel
                for byte in 0..<pixel where at[byte] != data[byte] { return true }
            }
        }
        return false
    }

    @Test("the board draws loaded, empty, failed and with a card in every lane, light and dark")
    func boardScreen() async {
        let rig = ShellRig()
        rig.scriptSignIn(ownerExists: true)
        rig.runtime.fakeSessions.token.value = "stored-made-up-token"
        let app = rig.makeModel()
        await app.start()
        let context = app.screens!
        rig.owner.script {
            $0.board = {
                Fixtures.board(
                    TaskState.allCases.map { Fixtures.boardTask($0, builder: Fixtures.builderID) }
                        + [Fixtures.boardTask(.working, holds: [.roundsExceeded])], reviewer: false)
            }
            $0.seats = { Fixtures.seats() }
        }
        let view = BoardView().environment(context)
        #expect(draws(view))
        #expect(draws(view.environment(\.colorScheme, .dark)))

        let failing = BoardModel(api: FakeOwnerAPI(), noteRead: { _ in })
        await failing.load()
        #expect(failing.state != .loading)
        #expect(draws(BoardContent(model: failing, open: { _ in })))

        let loaded = BoardModel(api: Fixtures.owner(board: Fixtures.board(
            TaskState.allCases.map { Fixtures.boardTask($0, builder: Fixtures.builderID) }
                + [Fixtures.boardTask(.working, holds: [.roundsExceeded])], reviewer: false)), noteRead: { _ in })
        await loaded.load()
        loaded.showCancelled = true
        #expect(draws(BoardContent(model: loaded, open: { _ in })))
        #expect(draws(BoardContent(model: loaded, open: { _ in }).environment(\.colorScheme, .dark)))
        let empty = BoardModel(api: Fixtures.owner(board: Fixtures.board([])), noteRead: { _ in })
        await empty.load()
        #expect(draws(BoardContent(model: empty, open: { _ in })))
    }
}
