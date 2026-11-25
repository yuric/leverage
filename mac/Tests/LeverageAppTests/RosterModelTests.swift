import Foundation
import LeverageKit
import LeverageTestSupport
import SwiftUI
import Testing

@testable import LeverageApp

private typealias Fixtures = AgentFixtures

extension FollowTiming {
    /// Short waits, so a test that follows a request does not sit still. The
    /// give-up is only a ceiling for the fake to answer, so it follows the
    /// run's patience.
    static let quick = FollowTiming(
        waitSeconds: 1, idleDelay: .milliseconds(2), retryDelay: .milliseconds(2),
        giveUpAfter: Patience.scaled(.seconds(30)))
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
        #expect(row(model, Fixtures.reviewerID)?.roleLine == "Reviewer. Not running.")
        #expect(row(model, Fixtures.ownID)?.roleLine == "Builder. Connected by prompt.")
    }

    @Test("a running agent with no task says it is waiting for work")
    func waitingForWork() async {
        let model = makeModel(Fixtures.owner())
        await model.load()
        #expect(row(model, Fixtures.builderID)?.roleLine == "Builder. Running. Waiting for work.")
    }

    @Test("a Codex or Grok agent shows the tool's default effort, whatever effort it was given")
    func effortDefaultWhereNotTaken() async {
        var list = Fixtures.seats().seats
        list[1] = Fixtures.seat(
            Fixtures.reviewerID, name: "Codex, Team", role: .reviewer, provider: .codex,
            credential: Fixtures.secondLoginID, run: .stopped, effort: "high")
        list[2] = Fixtures.seat(Fixtures.ownID, name: "Helper agent", provider: .grok, effort: "high")
        let model = makeModel(Fixtures.owner(seats: SeatsList(seats: list, asOfSeq: 12)))
        await model.load()
        #expect(row(model, Fixtures.reviewerID)?.detailLine == "Codex · The tool's default · Default effort · On")
        #expect(row(model, Fixtures.ownID)?.detailLine == "Grok · The tool's default · Default effort · On")
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
        #expect(row(model, Fixtures.reviewerID)?.detailLine == "Codex · The tool's default · Default effort · On")
        #expect(row(model, Fixtures.ownID)?.detailLine == "Grok · The tool's default · Default effort · Off")
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

    @Test("only a seat the app runs has Start or Stop, and only one that connects on its own has New prompt")
    func buttonsByKind() async {
        let model = makeModel(Fixtures.owner())
        await model.load()
        let running = row(model, Fixtures.builderID)
        let stopped = row(model, Fixtures.reviewerID)
        let own = row(model, Fixtures.ownID)
        #expect(running?.canStop == true && running?.canStart == false)
        #expect(stopped?.canStart == true && stopped?.canStop == false)
        #expect(own?.canStart == false && own?.canStop == false)
        #expect(running?.canIssueNewPrompt == false && stopped?.canIssueNewPrompt == false)
        #expect(own?.canIssueNewPrompt == true)
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

    // MARK: New prompt

    @Test("New prompt issues a replacement only after confirmation and copies only on request",
          arguments: LandingPromptConnection.allCases)
    func issuesNewPrompt(_ connection: LandingPromptConnection) async throws {
        let owner = Fixtures.owner()
        owner.script {
            $0.issueLandingPrompt = { Fixtures.issuedPrompt($0, connection: $1, key: $2) }
        }
        let board = Fixtures.pasteboard()
        let model = makeModel(owner, copy: board.copy)
        await model.load()
        model.prepareNewPrompt(Fixtures.ownID, connection: connection)
        let prompt = try #require(model.newPrompt)
        #expect(Fixtures.calls(owner, .issueLandingPrompt).isEmpty)
        await prompt.issue()
        let first = try #require(Fixtures.calls(owner, .issueLandingPrompt).last)
        #expect(first.path["id"] == Fixtures.ownID.contractString)
        #expect(first.body == .object(["connection": .string(connection.rawValue)]))
        #expect(prompt.state == .ready(Fixtures.landingText))
        #expect(board.copied.value.isEmpty)
        prompt.copyPrompt()
        #expect(board.copied.value == [Fixtures.landingText])
        model.closeNewPrompt()
        #expect(model.newPrompt == nil)
        #expect(prompt.state == .none)
        model.prepareNewPrompt(Fixtures.ownID, connection: connection)
        await model.newPrompt?.issue()
        let calls = Fixtures.calls(owner, .issueLandingPrompt)
        #expect(calls.count == 2)
        #expect(first.key != calls.last?.key)
    }

    @Test("New prompt is unavailable for a seat the app runs")
    func noPromptForAppSeat() async {
        let owner = Fixtures.owner()
        let model = makeModel(owner)
        await model.load()
        owner.forgetCalls()
        model.prepareNewPrompt(Fixtures.builderID, connection: .mcp)
        #expect(model.newPrompt == nil)
        #expect(owner.calls.isEmpty)
    }

    @Test("a refused New prompt shows the reason and leaves nothing to copy")
    func promptRefused() async throws {
        let owner = Fixtures.owner()
        owner.script {
            $0.issueLandingPrompt = { _, _, key in
                .refused(Refusal(code: .invalidState, ruleID: nil, reason: nil), key: key.value, command: .issueLandingPrompt)
            }
        }
        let board = Fixtures.pasteboard()
        let model = makeModel(owner, copy: board.copy)
        await model.load()
        model.prepareNewPrompt(Fixtures.ownID, connection: .http)
        let prompt = try #require(model.newPrompt)
        await prompt.issue()
        #expect(prompt.state == .failed(ShellCopy.refusalInvalidState.text))
        prompt.copyPrompt()
        #expect(board.copied.value.isEmpty)
    }

    @Test("a replacement containing a second token-shaped string is refused")
    func promptWithTokenShape() async throws {
        let owner = Fixtures.owner()
        owner.script {
            $0.issueLandingPrompt = {
                Fixtures.issuedPrompt($0, connection: $1, key: $2, text: Fixtures.landingText + " " + Fixtures.madeUpToken + "-other")
            }
        }
        let board = Fixtures.pasteboard()
        let model = makeModel(owner, copy: board.copy)
        await model.load()
        model.prepareNewPrompt(Fixtures.ownID, connection: .http)
        let prompt = try #require(model.newPrompt)
        await prompt.issue()
        #expect(prompt.state == .failed(ShellCopy.somethingWentWrong.text))
        prompt.copyPrompt()
        #expect(board.copied.value.isEmpty)
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
        #expect(await ShellFixtures.eventually(timeout: .seconds(30)) { model.rows.map(\.name) == ["Only one"] })
        model.detach()
        feed.stop()
    }

    @Test("it also reads again on a timer, because last polled and running are not events")
    func readsOnATimer() async {
        let owner = Fixtures.owner()
        let model = makeModel(owner)
        let keeping = Task { await model.keepCurrent(every: .milliseconds(5)) }
        #expect(await ShellFixtures.eventually(timeout: .seconds(30)) { Fixtures.calls(owner, .listSeats).count >= 3 })
        keeping.cancel()
        await keeping.value
        let after = Fixtures.calls(owner, .listSeats).count
        try? await Task.sleep(for: .milliseconds(40))
        #expect(Fixtures.calls(owner, .listSeats).count == after)
    }

    // MARK: the four words of an agent's state (HM-45)

    private func rowWords(_ model: RosterModel, _ id: UUID) -> String { row(model, id)?.roleLine ?? "" }

    @Test("a paused agent is Paused, and its row says pausing stops no run")
    func pausedWords() async {
        var list = Fixtures.seats().seats
        list[0] = Fixtures.seat(
            Fixtures.builderID, name: "Claude, Personal", credential: Fixtures.loginID, run: .running, paused: true)
        let model = makeModel(Fixtures.owner(seats: SeatsList(seats: list, asOfSeq: 12)))
        await model.load()
        let paused = row(model, Fixtures.builderID)
        #expect(paused?.roleLine == "Builder. Paused.")
        #expect(paused?.detailLine.hasSuffix("Paused") == true)
        let note = paused?.pausedNote ?? ""
        #expect(note.contains("does not stop its run"))
        #expect(note.contains("goes back to waiting for any agent"))
        #expect(BannedTerms.found(in: note).isEmpty)
        #expect(row(model, Fixtures.reviewerID)?.pausedNote == nil)
    }

    @Test("an agent that is turned off is Off, and one with no run is Not running")
    func offAndNotRunning() async {
        var list = Fixtures.seats().seats
        list[1] = Fixtures.seat(
            Fixtures.reviewerID, name: "Codex, Team", role: .reviewer, provider: .codex,
            credential: Fixtures.secondLoginID, run: .stopped, enabled: false)
        let model = makeModel(Fixtures.owner(seats: SeatsList(seats: list, asOfSeq: 12)))
        await model.load()
        #expect(rowWords(model, Fixtures.reviewerID) == "Reviewer. Off.")
        let notRunning = makeModel(Fixtures.owner())
        await notRunning.load()
        #expect(rowWords(notRunning, Fixtures.reviewerID) == "Reviewer. Not running.")
        #expect(row(notRunning, Fixtures.reviewerID)?.runChip?.text == "Not running")
    }

    @Test("a running agent whose own account and every account below it are unavailable is Waiting for the account")
    func waitingForAnAccount() async {
        let later = now.addingTimeInterval(3600)
        let list = CredentialsList(
            credentials: [
                Fixtures.account(Fixtures.loginID, name: "Personal", since: now.addingTimeInterval(-60), until: later, position: 1),
                Fixtures.account(
                    Fixtures.secondLoginID, name: "Team", provider: .codex, since: now.addingTimeInterval(-30),
                    until: later.addingTimeInterval(7200), position: 2),
            ], asOfSeq: 11)
        let model = makeModel(Fixtures.owner(credentials: list))
        await model.load()
        // The account that resets first.
        #expect(rowWords(model, Fixtures.builderID) == "Builder. Waiting for Claude, Personal.")
        // Stopped: it has no run, and says so.
        #expect(rowWords(model, Fixtures.reviewerID) == "Reviewer. Not running.")
        // Connects on its own: it has no account of its own to wait for.
        #expect(rowWords(model, Fixtures.ownID) == "Builder. Connected by prompt.")
    }

    @Test("an account whose reset time is known is named before one with no reset time")
    func knownResetBeforeUnknown() async {
        let list = CredentialsList(
            credentials: [
                Fixtures.account(Fixtures.loginID, name: "Personal", since: now.addingTimeInterval(-60), position: 1),
                Fixtures.account(
                    Fixtures.secondLoginID, name: "Team", provider: .codex, since: now.addingTimeInterval(-60),
                    until: now.addingTimeInterval(3600), position: 2),
            ], asOfSeq: 11)
        let model = makeModel(Fixtures.owner(credentials: list))
        await model.load()
        #expect(rowWords(model, Fixtures.builderID) == "Builder. Waiting for Codex, Team.")
    }

    @Test("a signed-out account below is the one waited for, because only the owner can bring it back")
    func waitingForASignedOutAccount() async {
        let list = CredentialsList(
            credentials: [
                Fixtures.account(
                    Fixtures.loginID, name: "Personal", since: now.addingTimeInterval(-60),
                    until: now.addingTimeInterval(3600), position: 1),
                Fixtures.account(Fixtures.secondLoginID, name: "Team", provider: .codex, state: .signedOut, position: 2),
            ], asOfSeq: 11)
        let model = makeModel(Fixtures.owner(credentials: list))
        await model.load()
        #expect(rowWords(model, Fixtures.builderID) == "Builder. Waiting for Codex, Team.")
    }

    @Test("an agent with one account free, its own or one below it, is not waiting; one above its own does not count")
    func notWaitingWhileAnAccountIsFree() async {
        let limited = now.addingTimeInterval(3600)
        let ownLimitedBelowFree = CredentialsList(
            credentials: [
                Fixtures.account(Fixtures.loginID, name: "Personal", since: now, until: limited, position: 1),
                Fixtures.account(Fixtures.secondLoginID, name: "Team", provider: .codex, position: 2),
            ], asOfSeq: 11)
        let below = makeModel(Fixtures.owner(credentials: ownLimitedBelowFree))
        await below.load()
        #expect(rowWords(below, Fixtures.builderID) == "Builder. Running. Waiting for work.")

        let aboveFreeOwnLimited = CredentialsList(
            credentials: [
                Fixtures.account(Fixtures.secondLoginID, name: "Team", provider: .codex, position: 1),
                Fixtures.account(Fixtures.loginID, name: "Personal", since: now, until: limited, position: 2),
            ], asOfSeq: 11)
        let above = makeModel(Fixtures.owner(credentials: aboveFreeOwnLimited))
        await above.load()
        #expect(rowWords(above, Fixtures.builderID) == "Builder. Waiting for Claude, Personal.")

        // A limit whose time has passed is no limit (HE-3).
        let passed = CredentialsList(
            credentials: [
                Fixtures.account(
                    Fixtures.loginID, name: "Personal", since: now.addingTimeInterval(-7200),
                    until: now.addingTimeInterval(-60), position: 1)
            ], asOfSeq: 11)
        let past = makeModel(Fixtures.owner(credentials: passed))
        await past.load()
        #expect(rowWords(past, Fixtures.builderID) == "Builder. Running. Waiting for work.")
    }

    @Test("a paused agent says Paused and an agent turned off says Off, even when its accounts are unavailable")
    func pausedOrOffBeatsWaiting() async {
        var list = Fixtures.seats().seats
        list[0] = Fixtures.seat(
            Fixtures.builderID, name: "Claude, Personal", credential: Fixtures.loginID, run: .running, paused: true)
        list[1] = Fixtures.seat(
            Fixtures.reviewerID, name: "Codex, Team", role: .reviewer, provider: .codex,
            credential: Fixtures.secondLoginID, run: .running, enabled: false)
        let credentials = CredentialsList(
            credentials: [
                Fixtures.account(Fixtures.loginID, name: "Personal", state: .signedOut, position: 1),
                Fixtures.account(Fixtures.secondLoginID, name: "Team", provider: .codex, state: .signedOut, position: 2),
            ], asOfSeq: 11)
        let model = makeModel(Fixtures.owner(seats: SeatsList(seats: list, asOfSeq: 12), credentials: credentials))
        await model.load()
        #expect(rowWords(model, Fixtures.builderID) == "Builder. Paused.")
        #expect(rowWords(model, Fixtures.reviewerID) == "Reviewer. Off.")
    }

    @Test("the account's name is the provider and the login's name, never its email or plan")
    func waitingNamesNoEmail() async {
        let list = CredentialsList(
            credentials: [
                Fixtures.account(
                    Fixtures.loginID, name: "Personal", since: now, until: now.addingTimeInterval(60), position: 1,
                    email: Fixtures.madeUpEmail, plan: Fixtures.madeUpPlan)
            ], asOfSeq: 11)
        let model = makeModel(Fixtures.owner(credentials: list))
        await model.load()
        for r in model.rows {
            for line in [r.roleLine, r.detailLine, r.loginLine ?? "", r.lastPolledLine, r.pausedNote ?? ""] {
                #expect(!line.contains("@") && !line.contains("made up"), "\(line)")
            }
        }
    }

    // MARK: Pause, Resume (HE-26)

    @Test("Pause is offered on an agent that is on and not paused; Resume only on a paused one; Change on every agent")
    func pauseButtons() async {
        var list = Fixtures.seats().seats
        list[0] = Fixtures.seat(
            Fixtures.builderID, name: "Claude, Personal", credential: Fixtures.loginID, run: .running, paused: true)
        list[1] = Fixtures.seat(
            Fixtures.reviewerID, name: "Codex, Team", role: .reviewer, provider: .codex,
            credential: Fixtures.secondLoginID, run: .stopped, enabled: false)
        let model = makeModel(Fixtures.owner(seats: SeatsList(seats: list, asOfSeq: 12)))
        await model.load()
        let paused = row(model, Fixtures.builderID)
        let off = row(model, Fixtures.reviewerID)
        let on = row(model, Fixtures.ownID)
        #expect(paused?.canPause == false && paused?.canResume == true)
        #expect(off?.canPause == false && off?.canResume == false)
        #expect(on?.canPause == true && on?.canResume == false)
        #expect([paused, off, on].allSatisfy { $0?.canChange == true })
    }

    @Test("Pause sends pause_seat for that agent under a new key and reads again; it follows no helper request")
    func pause() async {
        let owner = Fixtures.owner()
        owner.script { $0.pauseSeat = { _, key in Fixtures.plain(.pauseSeat, key: key) } }
        let model = makeModel(owner)
        await model.load()
        owner.forgetCalls()
        await model.pause(Fixtures.ownID)
        let sent = Fixtures.calls(owner, .pauseSeat)
        #expect(sent.count == 1 && sent.first?.path["id"] == Fixtures.ownID.contractString)
        #expect(sent.first?.key != nil)
        #expect(sent.first?.body == nil)
        #expect(Fixtures.calls(owner, .getHelperRequest).isEmpty)
        #expect(Fixtures.calls(owner, .listSeats).count == 1)
        #expect(model.failure(for: Fixtures.ownID) == nil)
        #expect(!model.isBusy(Fixtures.ownID))
    }

    @Test("Resume sends resume_seat for a paused agent, and nothing for one that is not paused")
    func resume() async {
        var list = Fixtures.seats().seats
        list[2] = Fixtures.seat(Fixtures.ownID, name: "Helper agent", provider: .grok, paused: true)
        let owner = Fixtures.owner(seats: SeatsList(seats: list, asOfSeq: 12))
        owner.script { $0.resumeSeat = { _, key in Fixtures.plain(.resumeSeat, key: key) } }
        let model = makeModel(owner)
        await model.load()
        owner.forgetCalls()
        await model.resume(Fixtures.ownID)
        await model.resume(Fixtures.builderID)
        let sent = Fixtures.calls(owner, .resumeSeat)
        #expect(sent.count == 1 && sent.first?.path["id"] == Fixtures.ownID.contractString)
        #expect(Fixtures.calls(owner, .listSeats).count == 1)
    }

    @Test("Pause sends nothing for an agent that is already paused, turned off or not on the list")
    func pauseOnlyWhereItMakesSense() async {
        var list = Fixtures.seats().seats
        list[0] = Fixtures.seat(
            Fixtures.builderID, name: "Claude, Personal", credential: Fixtures.loginID, run: .running, paused: true)
        list[1] = Fixtures.seat(
            Fixtures.reviewerID, name: "Codex, Team", role: .reviewer, provider: .codex,
            credential: Fixtures.secondLoginID, run: .stopped, enabled: false)
        let owner = Fixtures.owner(seats: SeatsList(seats: list, asOfSeq: 12))
        let model = makeModel(owner)
        await model.load()
        owner.forgetCalls()
        await model.pause(Fixtures.builderID)
        await model.pause(Fixtures.reviewerID)
        await model.pause(UUID())
        #expect(owner.calls.isEmpty)
    }

    @Test("Pause sent again after the network failed uses the same key; after an answer, a new one")
    func pauseKeys() async {
        let owner = Fixtures.owner()
        let attempts = Locked(0)
        owner.script {
            $0.pauseSeat = { _, key in
                if attempts.update({ $0 += 1; return $0 }) == 1 { throw URLError(.networkConnectionLost) }
                return Fixtures.plain(.pauseSeat, key: key)
            }
        }
        let model = makeModel(owner)
        await model.load()
        await model.pause(Fixtures.ownID)
        #expect(model.failure(for: Fixtures.ownID) == ShellCopy.cannotReach.text)
        await model.pause(Fixtures.ownID)
        await model.pause(Fixtures.ownID)
        let keys = Fixtures.calls(owner, .pauseSeat).map(\.key)
        #expect(keys.count == 3 && keys[0] == keys[1] && keys[1] != keys[2])
        #expect(model.failure(for: Fixtures.ownID) == nil)
    }

    @Test("a refused Pause shows the sentence for its code on that row, and a refused Resume too")
    func pauseRefused() async {
        let owner = Fixtures.owner()
        let refusal = Refusal(code: .invalidState, ruleID: nil, reason: nil)
        owner.script { $0.pauseSeat = { _, key in .refused(refusal, key: key.value, command: .pauseSeat) } }
        let model = makeModel(owner)
        await model.load()
        await model.pause(Fixtures.ownID)
        #expect(model.failure(for: Fixtures.ownID) == ShellCopy.refusalInvalidState.text)
        #expect(model.failure(for: Fixtures.builderID) == nil)
        await model.pause(Fixtures.ownID)
        let keys = Fixtures.calls(owner, .pauseSeat).map(\.key)
        #expect(keys.count == 2 && keys[0] != keys[1])
    }

    // MARK: Change (HM-51)

    @Test("Change opens the sheet with that agent's values and the logins it can move to")
    func beginChange() async {
        let model = makeModel(Fixtures.owner())
        await model.load()
        #expect(model.changing == nil)
        model.beginChange(Fixtures.builderID)
        let sheet = model.changing
        #expect(sheet?.name == "Claude, Personal")
        #expect(sheet?.credentialID == Fixtures.loginID)
        #expect(sheet?.enabled == true)
        #expect(sheet?.loginChoices.map(\.label) == ["Claude, Personal", "Codex, Team"])
        model.cancelChange()
        #expect(model.changing == nil)
        model.beginChange(UUID())
        #expect(model.changing == nil)
    }

    @Test("a saved change closes the sheet and reads the roster again")
    func changeSaved() async {
        let owner = Fixtures.owner()
        owner.script { $0.changeSeat = { _, _, key in Fixtures.plain(.changeSeat, key: key) } }
        let model = makeModel(owner)
        await model.load()
        owner.forgetCalls()
        model.beginChange(Fixtures.ownID)
        model.changing?.name = "Renamed"
        await model.changing?.save()
        #expect(Fixtures.calls(owner, .changeSeat).count == 1)
        #expect(model.changing == nil)
        #expect(Fixtures.calls(owner, .listSeats).count == 1)
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

    // MARK: an orchestrator the eval suite did not cover (RV-5)

    private let note = "Not tested for checking tasks."
    private let orchestratorID = UUID(uuidString: "99990000-1111-4111-8111-999900001111")!

    private func orchestratorRow(
        provider: Provider = .claude, model: String? = nil, credential: UUID? = Fixtures.loginID,
        role: SeatRole = .orchestrator, tested: [Provider]
    ) async -> RosterRow? {
        let seat = Fixtures.seat(
            orchestratorID, name: "Checker", role: role, provider: provider, credential: credential,
            run: credential == nil ? nil : .running, model: model)
        let owner = Fixtures.owner(seats: SeatsList(seats: [seat], asOfSeq: 12))
        let model = RosterModel(
            api: owner, noteRead: { _ in }, copy: { _ in }, now: { now }, timing: .quick, testedProviders: tested)
        await model.load()
        return model.rows.first
    }

    @Test("an orchestrator on a login of a provider that is not tested says so on its row, and the row says what it is")
    func rowNoteForAnUntestedProvider() async {
        let row = await orchestratorRow(tested: [.codex])
        #expect(row?.notTestedNote == note)
        #expect(row?.roleLine == "Orchestrator. Running. Waiting for work.")
        #expect(row?.canStop == true, "nothing is disabled by the note")
    }

    @Test("an orchestrator on a tested provider, with no model chosen, has no note")
    func rowNoNoteForATestedProvider() async {
        let row = await orchestratorRow(tested: [.claude])
        #expect(row != nil)
        #expect(row?.notTestedNote == nil)
    }

    @Test("a model chosen brings the note on a tested provider")
    func rowNoteForAChosenModel() async {
        #expect(await orchestratorRow(model: "some-model", tested: [.claude])?.notTestedNote == note)
        #expect(await orchestratorRow(model: "", tested: [.claude])?.notTestedNote == nil)
    }

    @Test("an orchestrator that connects on its own has the note whatever its provider")
    func rowNoteForConnectingOnItsOwn() async {
        let row = await orchestratorRow(credential: nil, tested: [.claude])
        #expect(row?.notTestedNote == note)
        #expect(row?.roleLine == "Orchestrator. Connected by prompt.")
    }

    @Test("with an empty tested list every orchestrator row has the note, and no other role does")
    func rowNoteOnlyForOrchestrators() async {
        #expect(await orchestratorRow(tested: [])?.notTestedNote == note)
        for role in [SeatRole.builder, .reviewer, .planner] {
            #expect(await orchestratorRow(model: "some-model", role: role, tested: [])?.notTestedNote == nil, "\(role)")
        }
    }

    @Test("a General row uses the General eval list and says how the agent connected")
    func generalRowCoverage() {
        let seat = Fixtures.seat(orchestratorID, name: "General agent", role: .general, credential: nil)
        let untested = RosterRow(seat: seat, loginName: nil, doing: nil, now: now, generalTestedProviders: [])
        #expect(untested.roleLine == "General. Connected by prompt.")
        #expect(untested.notTestedNote == note)
        let tested = RosterRow(seat: seat, loginName: nil, doing: nil, now: now, generalTestedProviders: [seat.provider])
        #expect(tested.notTestedNote == note)
        let registry = RosterRow(seat: seat, loginName: nil, doing: nil, now: now)
        #expect(registry.notTestedNote == note)

        for model in [nil, "custom-model"] as [String?] {
            let native = Fixtures.seat(
                orchestratorID, name: "General agent", role: .general, credential: Fixtures.loginID, model: model)
            let covered = RosterRow(seat: native, loginName: nil, doing: nil, now: now,
                                    generalTestedProviders: [native.provider])
            #expect(covered.notTestedNote == (model == nil ? nil : note))
            let uncovered = RosterRow(seat: native, loginName: nil, doing: nil, now: now,
                                      generalTestedProviders: [.codex])
            #expect(uncovered.notTestedNote == note)
        }
    }

    @Test("native checkers show the note based on their role's shipped eval coverage")
    func shippedCheckerCoverage() {
        let coverage: [(SeatRole, [Provider])] = [
            (.general, ContractLists.generalTestedProviders),
            (.orchestrator, ContractLists.orchestratorTestedProviders),
        ]
        for (role, tested) in coverage {
            for provider in Provider.allCases where provider.kind == .login {
                let seat = Fixtures.seat(
                    orchestratorID, name: "Checker", role: role, provider: provider, credential: Fixtures.loginID)
                let row = RosterRow(seat: seat, loginName: nil, doing: nil, now: now)
                #expect(row.notTestedNote == (tested.contains(provider) ? nil : note), "\(role) on \(provider)")
            }
        }
    }

    @Test("a planner's row says Planner, like the roster says every other role")
    func plannerRow() async {
        let row = await orchestratorRow(role: .planner, tested: [])
        #expect(row?.roleLine == "Planner. Running. Waiting for work.")
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
        let checker = await orchestratorRow(tested: [])
        #expect(checker?.notTestedNote == note)
        let checkerModel = RosterModel(
            api: Fixtures.owner(seats: SeatsList(seats: [Fixtures.seat(orchestratorID, name: "Checker", role: .orchestrator, credential: Fixtures.loginID, run: .running)], asOfSeq: 1)),
            noteRead: { _ in }, copy: { _ in }, now: { now }, timing: .quick, testedProviders: [])
        await checkerModel.load()
        #expect(draw(checkerModel, false))
        #expect(draw(checkerModel, true))
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

extension RosterModelTests {
    @Test("The menu drawn for both connection types has no replacement prompt")
    func noReplacementPromptInMenu() {
        let native = AgentFixtures.seat(AgentFixtures.builderID, name: "Native", credential: AgentFixtures.loginID)
        let prompt = AgentFixtures.seat(AgentFixtures.ownID, name: "Prompt")
        for (seat, expected) in [(native, ["Start", "Pause", "Change", "Remove"]), (prompt, ["Pause", "Change", "Remove"])] {
            let row = RosterRow(seat: seat, loginName: nil, doing: nil, now: Date())
            #expect(RosterRowView.menuItems(for: row).map(\.text) == expected)
        }
    }

    @Test("Roster shows Native defaults, Prompt reports and the permissions the agent has")
    func reportsAndPermissions() {
        let native = Seat(id: UUID(), name: "Native", provider: .claude, role: .builder,
                          credentialID: AgentFixtures.loginID, permissions: SeatPermissions(work: false, deliver: false, create: false))
        let unreported = AgentFixtures.seat(AgentFixtures.ownID, name: "Prompt")
        let reported = AgentFixtures.seat(AgentFixtures.ownID, name: "Prompt", provider: .codex, model: "gpt-example", effort: "high")
        func row(_ seat: Seat) -> RosterRow { RosterRow(seat: seat, loginName: nil, doing: nil, now: Date()) }
        #expect(row(native).detailLine.contains("The tool's default"))
        #expect(row(native).permissionsLine == "May: nothing")
        #expect(row(unreported).detailLine.contains("Not reported yet"))
        #expect(row(reported).detailLine.contains("gpt-example · high effort"))
        #expect(row(reported).permissionsLine == "May: work on tasks, deliver tasks, create tasks")
    }
}
