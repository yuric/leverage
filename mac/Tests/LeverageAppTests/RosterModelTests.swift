import Foundation
import LeverageKit
import LeverageTestSupport
import SwiftUI
import Testing

@testable import LeverageApp

private typealias Fixtures = AgentFixtures

extension FollowTiming {
    /// Short waits, so a test that follows a request does not sit still.
    static let quick = FollowTiming(
        waitSeconds: 1, idleDelay: .milliseconds(2), retryDelay: .milliseconds(2), giveUpAfter: .seconds(3))
}

@MainActor
@Suite("RosterModel")
struct RosterModelTests {
    private let now = Date(timeIntervalSince1970: 1_780_000_600)

    private func makeModel(
        _ owner: FakeOwnerAPI, reads: Locked<[Int]> = Locked([]),
        copy: @escaping @MainActor (String) -> Void = { _ in }
    ) -> RosterModel {
        RosterModel(
            api: owner, noteRead: { seq in reads.update { $0.append(seq) } }, copy: copy, now: { now }, timing: .quick)
    }

    private func row(_ model: RosterModel, _ id: UUID) -> RosterRow? { model.rows.first { $0.id == id } }

    // MARK: loading, empty, loaded

    @Test("a new roster is loading and shows nothing")
    func startsLoading() {
        let model = makeModel(FakeOwnerAPI())
        #expect(model.state == .loading)
        #expect(model.rows.isEmpty)
    }

    @Test("a roster with no agents is loaded and empty")
    func empty() async {
        let model = makeModel(Fixtures.owner(seats: SeatsList(seats: [], asOfSeq: 3)))
        await model.load()
        #expect(model.state == .loaded)
        #expect(model.rows.isEmpty)
    }

    @Test("every agent is a row, in the order the server gives, and a removed one is left out")
    func rows() async {
        var list = Fixtures.seats().seats
        list.append(Fixtures.seat(UUID(), name: "Gone", removed: now))
        let model = makeModel(Fixtures.owner(seats: SeatsList(seats: list, asOfSeq: 12)))
        await model.load()
        #expect(model.state == .loaded)
        #expect(model.rows.map(\.name) == ["Claude, Personal", "Codex, Team", "Helper agent"])
    }

    @Test("the position noted is the lowest of the reads the roster made")
    func notesLowestPosition() async {
        let reads = Locked<[Int]>([])
        let model = makeModel(
            Fixtures.owner(seats: Fixtures.seats(asOfSeq: 12), credentials: Fixtures.credentials(asOfSeq: 11)), reads: reads)
        await model.load()
        #expect(reads.value == [9])
        let again = Locked<[Int]>([])
        let board = Fixtures.board(building: "x", by: Fixtures.builderID, asOfSeq: 30)
        let other = makeModel(
            Fixtures.owner(seats: Fixtures.seats(asOfSeq: 12), credentials: Fixtures.credentials(asOfSeq: 11), board: board),
            reads: again)
        await other.load()
        #expect(again.value == [11])
    }

    @Test("a row says the role, then what the agent is doing, in plain words")
    func rowSentences() async {
        let board = Fixtures.board(building: "Fix rounding in invoice totals", by: Fixtures.builderID)
        let model = makeModel(Fixtures.owner(board: board))
        await model.load()
        #expect(row(model, Fixtures.builderID)?.roleLine == "Builder. Building Fix rounding in invoice totals.")
        #expect(row(model, Fixtures.reviewerID)?.roleLine == "Reviewer. Stopped.")
        #expect(row(model, Fixtures.ownID)?.roleLine == "Builder. Connects on its own.")
    }

    @Test("a running agent with no task says it is waiting for work")
    func waitingForWork() async {
        let model = makeModel(Fixtures.owner())
        await model.load()
        #expect(row(model, Fixtures.builderID)?.roleLine == "Builder. Running. Waiting for work.")
    }

    @Test("a row names its login, its model and effort or their defaults, and on or off")
    func rowDetails() async {
        var list = Fixtures.seats().seats
        list[0] = Fixtures.seat(
            Fixtures.builderID, name: "Claude, Personal", credential: Fixtures.loginID, run: .running,
            model: "some-model", effort: "high")
        list[2] = Fixtures.seat(Fixtures.ownID, name: "Helper agent", provider: .grok, enabled: false)
        let model = makeModel(Fixtures.owner(seats: SeatsList(seats: list, asOfSeq: 12)))
        await model.load()
        #expect(row(model, Fixtures.builderID)?.detailLine == "Claude · some-model · high effort · On")
        #expect(row(model, Fixtures.builderID)?.loginLine == "Runs on Personal.")
        #expect(row(model, Fixtures.reviewerID)?.detailLine == "Codex · Default model · Default effort · On")
        #expect(row(model, Fixtures.ownID)?.detailLine == "Grok · Default model · Default effort · Off")
        #expect(row(model, Fixtures.ownID)?.loginLine == nil)
    }

    @Test("last polled says when, or that the agent has not asked yet")
    func lastPolled() async {
        var list = Fixtures.seats().seats
        list[0] = Fixtures.seat(
            Fixtures.builderID, name: "Claude, Personal", credential: Fixtures.loginID, run: .running,
            lastPolled: now.addingTimeInterval(-120))
        let model = makeModel(Fixtures.owner(seats: SeatsList(seats: list, asOfSeq: 12)))
        await model.load()
        #expect(row(model, Fixtures.builderID)?.lastPolledLine.hasPrefix("Last asked for work") == true)
        #expect(row(model, Fixtures.reviewerID)?.lastPolledLine == "Has not asked for work yet.")
    }

    @Test("only a seat the app runs has Start or Stop, and only one that connects on its own has Copy landing prompt")
    func buttonsByKind() async {
        let model = makeModel(Fixtures.owner())
        await model.load()
        let running = row(model, Fixtures.builderID)
        let stopped = row(model, Fixtures.reviewerID)
        let own = row(model, Fixtures.ownID)
        #expect(running?.canStop == true && running?.canStart == false)
        #expect(stopped?.canStart == true && stopped?.canStop == false)
        #expect(own?.canStart == false && own?.canStop == false)
        #expect(running?.canCopyLandingPrompt == false && stopped?.canCopyLandingPrompt == false)
        #expect(own?.canCopyLandingPrompt == true)
    }

    // MARK: refused, cannot reach, signed out

    @Test("a read that cannot reach the server shows one plain line, and keeps the rows already shown")
    func cannotReach() async {
        let owner = Fixtures.owner()
        let model = makeModel(owner)
        await model.load()
        #expect(model.rows.count == 3)
        owner.script { $0.seats = { throw URLError(.cannotConnectToHost) } }
        await model.load()
        #expect(model.state == .failed(.cannotReach))
        #expect(model.rows.count == 3)
    }

    @Test("a refused read shows the sentence for its code")
    func refusedRead() async {
        let owner = Fixtures.owner()
        owner.script { $0.seats = { throw LeverageClientError.refused(Refusal(code: .forbidden, ruleID: nil, reason: nil)) } }
        let model = makeModel(owner)
        await model.load()
        #expect(model.state == .failed(.refusalForbidden))
    }

    @Test("a 401 shows the signed-out state")
    func signedOut() async {
        let owner = Fixtures.owner()
        owner.script { $0.seats = { throw ShellFixtures.unauthenticated() } }
        let model = makeModel(owner)
        await model.load()
        #expect(model.state == .signedOut)
    }

    @Test("the credentials and the board are a nicety: without them the roster still shows")
    func nicetiesMayFail() async {
        let owner = Fixtures.owner()
        owner.script {
            $0.credentials = { throw URLError(.timedOut) }
            $0.board = { throw URLError(.timedOut) }
        }
        let model = makeModel(owner)
        await model.load()
        #expect(model.state == .loaded)
        #expect(model.rows.count == 3)
        #expect(row(model, Fixtures.builderID)?.loginLine == nil)
    }

    // MARK: Start and Stop

    @Test("Start sends start_seat for that agent under a new key, follows its request and reads again")
    func start() async {
        let requestID = UUID()
        let owner = Fixtures.owner()
        owner.script {
            $0.startSeat = { _, key in Fixtures.plain(.startSeat, key: key, helperRequest: requestID) }
            $0.helperRequest = { _, _, _ in Fixtures.request(requestID, kind: .startSeat, state: .finished, result: Fixtures.finished()) }
        }
        let model = makeModel(owner)
        await model.load()
        owner.forgetCalls()
        await model.start(Fixtures.reviewerID)
        let sent = Fixtures.calls(owner, .startSeat)
        #expect(sent.count == 1)
        #expect(sent.first?.path["id"] == Fixtures.reviewerID.contractString)
        #expect(sent.first?.key != nil)
        #expect(Fixtures.calls(owner, .getHelperRequest).count == 1)
        #expect(Fixtures.calls(owner, .listSeats).count == 1)
        #expect(model.failure(for: Fixtures.reviewerID) == nil)
        #expect(!model.isBusy(Fixtures.reviewerID))
    }

    @Test("Start sends nothing for an agent that connects on its own, or one already running")
    func startOnlyWhereItMakesSense() async {
        let owner = Fixtures.owner()
        let model = makeModel(owner)
        await model.load()
        owner.forgetCalls()
        await model.start(Fixtures.ownID)
        await model.start(Fixtures.builderID)
        await model.stop(Fixtures.ownID)
        await model.stop(Fixtures.reviewerID)
        #expect(owner.calls.isEmpty)
    }

    @Test("Stop sends stop_seat for that agent")
    func stop() async {
        let owner = Fixtures.owner()
        owner.script { $0.stopSeat = { _, key in Fixtures.plain(.stopSeat, key: key) } }
        let model = makeModel(owner)
        await model.load()
        await model.stop(Fixtures.builderID)
        #expect(Fixtures.calls(owner, .stopSeat).first?.path["id"] == Fixtures.builderID.contractString)
    }

    @Test("a start whose request fails says so on that row, in plain words")
    func startFails() async {
        let requestID = UUID()
        let owner = Fixtures.owner()
        owner.script {
            $0.startSeat = { _, key in Fixtures.plain(.startSeat, key: key, helperRequest: requestID) }
            $0.helperRequest = { _, _, _ in
                Fixtures.request(requestID, kind: .startSeat, state: .failed, result: Fixtures.finished(.failed))
            }
        }
        let model = makeModel(owner)
        await model.load()
        await model.start(Fixtures.reviewerID)
        #expect(model.failure(for: Fixtures.reviewerID) == "Codex, Team could not start. Check its login in Credentials.")
        #expect(model.failure(for: Fixtures.builderID) == nil)
    }

    @Test("Start sent again after the network failed uses the same key; after an answer it uses a new one")
    func startKeys() async {
        let owner = Fixtures.owner()
        let attempts = Locked(0)
        owner.script {
            $0.startSeat = { _, key in
                if attempts.update({ $0 += 1; return $0 }) == 1 { throw URLError(.networkConnectionLost) }
                return Fixtures.plain(.startSeat, key: key)
            }
        }
        let model = makeModel(owner)
        await model.load()
        await model.start(Fixtures.reviewerID)
        #expect(model.failure(for: Fixtures.reviewerID) == ShellCopy.cannotReach.text)
        await model.start(Fixtures.reviewerID)
        let keys = Fixtures.calls(owner, .startSeat).map(\.key)
        #expect(keys.count == 2 && keys[0] == keys[1])
        #expect(model.failure(for: Fixtures.reviewerID) == nil)
        await model.start(Fixtures.reviewerID)
        let all = Fixtures.calls(owner, .startSeat).map(\.key)
        #expect(all.count == 3 && all[2] != all[1])
    }

    @Test("a refused start shows the sentence for its code and does not keep its key")
    func startRefused() async {
        let owner = Fixtures.owner()
        let refusal = Refusal(code: .invalidState, ruleID: nil, reason: nil)
        owner.script { $0.startSeat = { _, key in .refused(refusal, key: key.value, command: .startSeat) } }
        let model = makeModel(owner)
        await model.load()
        await model.start(Fixtures.reviewerID)
        #expect(model.failure(for: Fixtures.reviewerID) == ShellCopy.refusalInvalidState.text)
        await model.start(Fixtures.reviewerID)
        let keys = Fixtures.calls(owner, .startSeat).map(\.key)
        #expect(keys.count == 2 && keys[0] != keys[1])
    }

    // MARK: Remove

    @Test("Remove asks first; Cancel sends nothing")
    func removeAsksFirst() async {
        let owner = Fixtures.owner()
        let model = makeModel(owner)
        await model.load()
        model.askToRemove(Fixtures.ownID)
        #expect(model.pendingRemoval?.id == Fixtures.ownID)
        model.cancelRemoval()
        #expect(model.pendingRemoval == nil)
        await model.confirmRemoval()
        #expect(Fixtures.calls(owner, .removeSeat).isEmpty)
    }

    @Test("the confirmation says the token stops working at once and what the agent has goes back to waiting")
    func removeConfirmationWords() async {
        let model = makeModel(Fixtures.owner())
        await model.load()
        model.askToRemove(Fixtures.ownID)
        let pending = model.pendingRemoval
        #expect(pending?.title == "Remove Helper agent?")
        #expect(pending?.message.contains("token stops working at once") == true)
        #expect(pending?.message.contains("goes back to waiting") == true)
        let banned = BannedTerms.found(in: pending?.message ?? "")
        #expect(banned.isEmpty)
    }

    @Test("a confirmed removal sends remove_seat for that agent and reads again")
    func removeConfirmed() async {
        let owner = Fixtures.owner()
        owner.script { $0.removeSeat = { _, key in Fixtures.plain(.removeSeat, key: key) } }
        let model = makeModel(owner)
        await model.load()
        owner.forgetCalls()
        model.askToRemove(Fixtures.ownID)
        await model.confirmRemoval()
        let sent = Fixtures.calls(owner, .removeSeat)
        #expect(sent.count == 1 && sent.first?.path["id"] == Fixtures.ownID.contractString)
        #expect(model.pendingRemoval == nil)
        #expect(Fixtures.calls(owner, .listSeats).count == 1)
    }

    @Test("a removal that cannot reach the server keeps its key for the next try")
    func removeKeyKept() async {
        let owner = Fixtures.owner()
        let attempts = Locked(0)
        owner.script {
            $0.removeSeat = { _, key in
                if attempts.update({ $0 += 1; return $0 }) == 1 { throw URLError(.timedOut) }
                return Fixtures.plain(.removeSeat, key: key)
            }
        }
        let model = makeModel(owner)
        await model.load()
        model.askToRemove(Fixtures.ownID)
        await model.confirmRemoval()
        #expect(model.failure(for: Fixtures.ownID) == ShellCopy.cannotReach.text)
        model.askToRemove(Fixtures.ownID)
        await model.confirmRemoval()
        let keys = Fixtures.calls(owner, .removeSeat).map(\.key)
        #expect(keys.count == 2 && keys[0] == keys[1])
    }

    // MARK: Copy landing prompt

    @Test("Copy landing prompt fetches the prompt of that agent and copies it, each time it is chosen")
    func copyLandingPrompt() async {
        let owner = Fixtures.owner()
        owner.script { $0.landingPrompt = { _ in LandingPrompt(text: "Read your rules first.") } }
        let board = Fixtures.pasteboard()
        let model = makeModel(owner, copy: board.copy)
        await model.load()
        await model.copyLandingPrompt(Fixtures.ownID)
        await model.copyLandingPrompt(Fixtures.ownID)
        #expect(board.copied.value == ["Read your rules first.", "Read your rules first."])
        #expect(Fixtures.calls(owner, .getLandingPrompt).count == 2)
        #expect(Fixtures.calls(owner, .getLandingPrompt).first?.path["id"] == Fixtures.ownID.contractString)
        #expect(model.copiedPrompt == Fixtures.ownID)
    }

    @Test("a seat the app runs has no landing prompt: nothing is asked and nothing is copied")
    func noPromptForAppSeat() async {
        let owner = Fixtures.owner()
        let board = Fixtures.pasteboard()
        let model = makeModel(owner, copy: board.copy)
        await model.load()
        owner.forgetCalls()
        await model.copyLandingPrompt(Fixtures.builderID)
        #expect(owner.calls.isEmpty)
        #expect(board.copied.value.isEmpty)
    }

    @Test("a prompt the server refuses is not copied, and the row says why")
    func promptRefused() async {
        let owner = Fixtures.owner()
        owner.script {
            $0.landingPrompt = { _ in throw LeverageClientError.refused(Refusal(code: .invalidState, ruleID: nil, reason: nil)) }
        }
        let board = Fixtures.pasteboard()
        let model = makeModel(owner, copy: board.copy)
        await model.load()
        await model.copyLandingPrompt(Fixtures.ownID)
        #expect(board.copied.value.isEmpty)
        #expect(model.failure(for: Fixtures.ownID) == ShellCopy.refusalInvalidState.text)
        #expect(model.copiedPrompt == nil)
    }

    @Test("a prompt that holds something shaped like a token is never copied")
    func promptWithTokenShape() async {
        let owner = Fixtures.owner()
        owner.script { $0.landingPrompt = { _ in LandingPrompt(text: "Sign in with \(Fixtures.madeUpToken).") } }
        let board = Fixtures.pasteboard()
        let model = makeModel(owner, copy: board.copy)
        await model.load()
        await model.copyLandingPrompt(Fixtures.ownID)
        #expect(board.copied.value.isEmpty)
        #expect(model.failure(for: Fixtures.ownID) == ShellCopy.somethingWentWrong.text)
    }

    // MARK: staying current

    @Test("an event from the tail reads the roster again")
    func readsAgainOnEvents() async {
        let owner = Fixtures.owner()
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
        let model = RosterModel(api: owner, noteRead: { feed.noteRead(asOfSeq: $0) }, copy: { _ in }, now: { now }, timing: .quick)
        model.attach(to: feed)
        await model.load()
        #expect(model.rows.count == 3)
        owner.script { $0.seats = { SeatsList(seats: [Fixtures.seat(Fixtures.ownID, name: "Only one")], asOfSeq: 13) } }
        batches.update { $0.append(EventsPage(events: [ShellFixtures.event(seq: 13)], nextAfterSeq: 13)) }
        #expect(await ShellFixtures.eventually { model.rows.map(\.name) == ["Only one"] })
        model.detach()
        feed.stop()
    }

    @Test("it also reads again on a timer, because last polled and running are not events")
    func readsOnATimer() async {
        let owner = Fixtures.owner()
        let model = makeModel(owner)
        let keeping = Task { await model.keepCurrent(every: .milliseconds(5)) }
        #expect(await ShellFixtures.eventually { Fixtures.calls(owner, .listSeats).count >= 3 })
        keeping.cancel()
        await keeping.value
        let after = Fixtures.calls(owner, .listSeats).count
        try? await Task.sleep(for: .milliseconds(40))
        #expect(Fixtures.calls(owner, .listSeats).count == after)
    }

    // MARK: words

    @Test("no sentence of the roster uses a banned word")
    func plainWords() async {
        let board = Fixtures.board(building: "Fix rounding in invoice totals", by: Fixtures.builderID)
        let model = makeModel(Fixtures.owner(board: board))
        await model.load()
        for row in model.rows {
            for line in [row.roleLine, row.detailLine, row.loginLine ?? "", row.lastPolledLine] {
                #expect(BannedTerms.found(in: line).isEmpty, "\(line)")
            }
        }
    }

    // MARK: the screen

    @Test("the roster draws loaded, empty, failed and with its confirmation, light and dark")
    func renders() async {
        let loaded = makeModel(Fixtures.owner(board: Fixtures.board(building: "Fix rounding", by: Fixtures.builderID)))
        await loaded.load()
        let draw = { (model: RosterModel, dark: Bool) in
            Fixtures.draws(RosterContent(model: model, connect: {}, openCredentials: {}).environment(\.colorScheme, dark ? .dark : .light))
        }
        #expect(draw(loaded, false))
        #expect(draw(loaded, true))
        let empty = makeModel(Fixtures.owner(seats: SeatsList(seats: [], asOfSeq: 1)))
        await empty.load()
        #expect(draw(empty, false))
        let owner = Fixtures.owner()
        owner.script { $0.seats = { throw URLError(.timedOut) } }
        let failed = makeModel(owner)
        await failed.load()
        #expect(draw(failed, false))
    }
}
