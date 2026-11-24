import Foundation
import LeverageKit
import LeverageTestSupport
import SwiftUI
import Testing

@testable import LeverageApp

private typealias Fixtures = AgentFixtures

/// The Handoff tab's rows (HM-34 to HM-37): one list of every account, in the
/// order the server gives, numbered 1 to n, each naming the account it hands
/// off to and the last login handing off to nobody. Names only.
@MainActor
@Suite("HandoffModel")
struct HandoffModelTests {
    private let now = Date(timeIntervalSince1970: 1_780_000_600)
    private let thirdID = UUID(uuidString: "99999999-9999-4999-8999-999999999999")!

    private func makeModel(
        _ owner: FakeOwnerAPI, reads: Locked<[Int]> = Locked([])
    ) -> HandoffModel {
        HandoffModel(
            api: owner, noteRead: { seq in reads.update { $0.append(seq) } }, now: { now },
            calendar: Fixtures.utc, locale: Fixtures.usEnglish)
    }

    private func owner(
        _ credentials: [CredentialWithReading], seats: [Seat] = [], asOfSeq: Int = 11
    ) -> FakeOwnerAPI {
        let owner = FakeOwnerAPI()
        owner.script {
            $0.credentials = { CredentialsList(credentials: credentials, asOfSeq: asOfSeq) }
            $0.seats = { SeatsList(seats: seats, asOfSeq: asOfSeq + 1) }
        }
        return owner
    }

    private func three() -> [CredentialWithReading] {
        [
            Fixtures.account(Fixtures.loginID, name: "Personal", position: 1),
            Fixtures.account(Fixtures.secondLoginID, name: "Team", provider: .codex, position: 2),
            Fixtures.account(thirdID, name: "Work", provider: .grok, position: 3),
        ]
    }

    private var clock: ResetClock {
        let at = now
        return ResetClock(now: { at }, calendar: Fixtures.utc, locale: Fixtures.usEnglish)
    }

    // MARK: loading and order

    @Test("a new Handoff tab is loading and shows no rows")
    func startsLoading() {
        let model = makeModel(FakeOwnerAPI())
        #expect(model.state == .loading)
        #expect(model.rows.isEmpty)
    }

    @Test("no accounts yet is loaded and empty")
    func empty() async {
        let model = makeModel(owner([]))
        await model.load()
        #expect(model.state == .loaded)
        #expect(model.rows.isEmpty)
    }

    @Test("the rows are in position order, numbered 1 to n, each with the account's provider and name")
    func rowsInOrder() async {
        let model = makeModel(owner(three()))
        await model.load()
        #expect(model.state == .loaded)
        #expect(model.rows.map(\.number) == [1, 2, 3])
        #expect(model.rows.map(\.name) == ["Claude, Personal", "Codex, Team", "Grok, Work"])
    }

    @Test("a list the server gives out of order is shown in position order, and gaps in the positions are closed")
    func outOfOrderWithGaps() async {
        let model = makeModel(owner([
            Fixtures.account(thirdID, name: "Work", provider: .grok, position: 9),
            Fixtures.account(Fixtures.loginID, name: "Personal", position: 2),
            Fixtures.account(Fixtures.secondLoginID, name: "Team", provider: .codex, position: 5),
        ]))
        await model.load()
        #expect(model.rows.map(\.number) == [1, 2, 3])
        #expect(model.rows.map(\.name) == ["Claude, Personal", "Codex, Team", "Grok, Work"])
    }

    @Test("each row hands off to the next one down, and the last hands off to nobody")
    func handsOffTo() async {
        let model = makeModel(owner(three()))
        await model.load()
        #expect(model.rows.map(\.handsOff) == [
            "Hands off to Codex, Team", "Hands off to Grok, Work", "Hands off to nobody",
        ])
    }

    @Test("a single account hands off to nobody")
    func single() async {
        let model = makeModel(owner([Fixtures.account(Fixtures.loginID, name: "Personal", position: 1)]))
        await model.load()
        #expect(model.rows.map(\.handsOff) == ["Hands off to nobody"])
    }

    @Test("an API token is in the list too, whatever its provider, named by its provider and name")
    func tokenInTheList() async {
        let model = makeModel(owner([
            Fixtures.account(Fixtures.loginID, name: "Personal", position: 1),
            Fixtures.account(thirdID, name: "Key", provider: .claudeApi, kind: .apiToken, state: .signedOut, position: 2),
            Fixtures.account(Fixtures.secondLoginID, name: "Team", provider: .codex, position: 3),
            Fixtures.account(UUID(), name: "Other", provider: .openrouter, kind: .apiToken, position: 4),
        ]))
        await model.load()
        #expect(model.rows.map(\.name) == ["Claude, Personal", "Claude API, Key", "Codex, Team", "OpenRouter, Other"])
        #expect(model.rows.map(\.handsOff) == [
            "Hands off to Codex, Team", "Not used for work yet", "Hands off to nobody", "Not used for work yet",
        ])
        #expect(model.rows.filter { $0.id == thirdID }.map(\.state) == ["Not used for work yet"])
    }

    // MARK: states (HM-34)

    @Test("a row's state is Ready, Working, At its limit until a time, At its limit, or Signed out")
    func states() async {
        let later = now.addingTimeInterval(3600)
        let list = [
            Fixtures.account(Fixtures.loginID, name: "Personal", position: 1),
            Fixtures.account(Fixtures.secondLoginID, name: "Team", provider: .codex, position: 2),
            Fixtures.account(thirdID, name: "Work", provider: .grok, state: .signedOut, position: 3),
            Fixtures.account(UUID(), name: "Limited", since: now.addingTimeInterval(-60), until: later, position: 4),
            Fixtures.account(UUID(), name: "Unknown", since: now.addingTimeInterval(-60), position: 5),
        ]
        let seats = [Fixtures.runningSeat(Fixtures.builderID, name: "Codex, Team", provider: .codex, credential: Fixtures.secondLoginID)]
        let model = makeModel(owner(list, seats: seats))
        await model.load()
        let time = ResetTime.text(for: later, clock: clock)
        #expect(model.rows.map(\.state) == [
            "Ready", "Working", "Signed out", "At its limit until \(time)", "At its limit",
        ])
    }

    @Test("a signed-out account is Signed out even at its limit, and a limit beats Working")
    func stateOrder() async throws {
        let later = now.addingTimeInterval(3600)
        let list = [
            Fixtures.account(
                Fixtures.loginID, name: "Personal", state: .signedOut, since: now, until: later, position: 1),
            Fixtures.account(Fixtures.secondLoginID, name: "Team", provider: .codex, since: now, until: later, position: 2),
        ]
        let seats = [Fixtures.runningSeat(Fixtures.reviewerID, name: "Codex, Team", provider: .codex, credential: Fixtures.secondLoginID)]
        let model = makeModel(owner(list, seats: seats))
        await model.load()
        try #require(model.rows.count == 2)
        #expect(model.rows[0].state == "Signed out")
        #expect(model.rows[1].state.hasPrefix("At its limit until"))
    }

    @Test("a limit whose time has passed is Ready; a reset time with no report of a limit is Ready")
    func passedLimit() async {
        let model = makeModel(owner([
            Fixtures.account(
                Fixtures.loginID, name: "Personal", since: now.addingTimeInterval(-7200), until: now.addingTimeInterval(-1),
                position: 1),
            Fixtures.credential(Fixtures.secondLoginID, name: "Team", provider: .codex, limitedUntil: now.addingTimeInterval(600)),
        ]))
        await model.load()
        #expect(model.rows.map(\.state) == ["Ready", "Ready"])
    }

    @Test("Working is a running agent whose run is on that account; a stopped agent, or one not on it, is not")
    func working() async {
        let seats = [
            Fixtures.runningSeat(Fixtures.builderID, name: "A", credential: Fixtures.loginID, runOn: Fixtures.secondLoginID),
            Fixtures.seat(Fixtures.reviewerID, name: "B", credential: thirdID, run: .stopped),
            // A stopped agent that still names a run's account is not working on it.
            Seat(
                id: UUID(), name: "C", provider: .claude, role: .builder, credentialID: Fixtures.loginID,
                runState: .stopped, runCredentialID: Fixtures.loginID),
        ]
        let model = makeModel(owner(three(), seats: seats))
        await model.load()
        #expect(model.rows.map(\.state) == ["Ready", "Working", "Ready"])
    }

    @Test("without the agents the tab still shows the accounts, all Ready")
    func seatsAreANicety() async {
        let owner = owner(three())
        owner.script { $0.seats = { throw URLError(.timedOut) } }
        let model = makeModel(owner)
        await model.load()
        #expect(model.state == .loaded)
        #expect(model.rows.count == 3)
        #expect(model.rows.map(\.state) == ["Ready", "Ready", "Ready"])
    }

    // MARK: names only

    @Test("no string a row produces holds an email, a plan or a masked label")
    func namesOnly() async {
        let model = makeModel(owner([
            Fixtures.account(
                Fixtures.loginID, name: "Personal", position: 1, email: Fixtures.madeUpEmail, plan: Fixtures.madeUpPlan),
            Fixtures.account(
                Fixtures.secondLoginID, name: "Key", provider: .openaiApi, kind: .apiToken, position: 2,
                email: Fixtures.madeUpEmail),
        ]))
        await model.load()
        model.previewDrop(of: Fixtures.loginID, over: Fixtures.secondLoginID)
        let hint = model.dropPreview?.hint
        for row in model.rows {
            for line in [row.name, row.state, row.handsOff, "\(row.number)", hint ?? ""] {
                #expect(!line.contains("@") && !line.contains("made up") && !line.contains("…abcd"), "\(line)")
                #expect(BannedTerms.found(in: line).isEmpty, "\(line)")
            }
        }
    }

    // MARK: reorder (CR-25, CR-27, CR-28)

    private func saveReorders(_ owner: FakeOwnerAPI) {
        owner.script {
            $0.reorderCredentials = { _, key in .completed(nil, key: key.value, command: .reorderCredentials) }
        }
    }

    private func ordersSent(by owner: FakeOwnerAPI) -> [JSONValue?] {
        owner.calls.filter { $0.operation == .reorderCredentials }.map { $0.body?["order"] }
    }

    private func order(_ ids: UUID...) -> JSONValue {
        .array(ids.map { .string($0.contractString) })
    }

    @Test("Move up and Move down send every id and stop at the ends")
    func moveButtons() async {
        let owner = owner(three())
        saveReorders(owner)
        let model = makeModel(owner)
        await model.load()
        let first = Fixtures.loginID
        let second = Fixtures.secondLoginID
        #expect(model.rows.map { model.canMoveUp($0.id) } == [false, true, true])
        #expect(model.rows.map { model.canMoveDown($0.id) } == [true, true, false])
        await model.moveUp(first)
        await model.moveDown(thirdID)
        #expect(ordersSent(by: owner).isEmpty)

        await model.moveDown(first)
        #expect(model.rows.map(\.id) == [second, first, thirdID])
        #expect(model.rows.map(\.number) == [1, 2, 3])
        await model.moveUp(first)
        #expect(model.rows.map(\.id) == [first, second, thirdID])
        #expect(ordersSent(by: owner) == [order(second, first, thirdID), order(first, second, thirdID)])
    }

    @Test("a drop previews the new number and marks the matching side of the target, then sends every id")
    func dragToReorder() async {
        let owner = owner(three())
        saveReorders(owner)
        let model = makeModel(owner)
        await model.load()
        let first = Fixtures.loginID
        let second = Fixtures.secondLoginID
        model.previewDrop(of: thirdID, over: first)
        #expect(model.dropPreview?.targetID == first)
        #expect(model.dropPreview?.above == true)
        #expect(model.dropPreview?.hint == "Drop to make Grok, Work number 1.")
        model.previewDrop(of: first, over: thirdID)
        #expect(model.dropPreview?.targetID == thirdID)
        #expect(model.dropPreview?.above == false)
        #expect(model.dropPreview?.hint == "Drop to make Claude, Personal number 3.")
        model.clearDropPreview(over: first)
        #expect(model.dropPreview?.targetID == thirdID)
        model.clearDropPreview(over: thirdID)
        #expect(model.dropPreview == nil)
        #expect(ordersSent(by: owner).isEmpty)

        await model.drop(first, over: thirdID)
        #expect(model.rows.map(\.id) == [second, thirdID, first])
        #expect(ordersSent(by: owner) == [order(second, thirdID, first)])
        #expect(model.dropPreview == nil)
    }

    @Test("a drop on itself or on a missing id has no hint and sends nothing")
    func invalidDrop() async {
        let owner = owner(three())
        saveReorders(owner)
        let model = makeModel(owner)
        await model.load()
        model.previewDrop(of: Fixtures.loginID, over: Fixtures.loginID)
        #expect(model.dropPreview == nil)
        await model.drop(Fixtures.loginID, over: Fixtures.loginID)
        let missing = UUID()
        model.previewDrop(of: missing, over: Fixtures.loginID)
        #expect(model.dropPreview == nil)
        await model.drop(missing, over: Fixtures.loginID)
        await model.drop(Fixtures.loginID, over: missing)
        #expect(ordersSent(by: owner).isEmpty)
    }

    @Test("a reload updates the drag hint when positions change and clears it if its target disappears")
    func reloadUpdatesDropPreview() async {
        let owner = owner(three())
        let model = makeModel(owner)
        await model.load()
        let first = Fixtures.loginID
        let target = thirdID
        model.previewDrop(of: first, over: target)
        #expect(model.dropPreview?.hint == "Drop to make Claude, Personal number 3.")
        owner.script {
            $0.credentials = {
                CredentialsList(credentials: [
                    Fixtures.account(Fixtures.secondLoginID, name: "Team", provider: .codex, position: 1),
                    Fixtures.account(target, name: "Work", provider: .grok, position: 2),
                    Fixtures.account(first, name: "Personal", position: 3),
                ], asOfSeq: 12)
            }
        }
        await model.load()
        #expect(model.dropPreview?.targetID == target)
        #expect(model.dropPreview?.hint == "Drop to make Claude, Personal number 2.")
        #expect(model.dropPreview?.above == true)
        owner.script {
            $0.credentials = {
                CredentialsList(credentials: [Fixtures.account(first, name: "Personal", position: 1)], asOfSeq: 13)
            }
        }
        await model.load()
        #expect(model.dropPreview == nil)
    }

    @Test("a read during a move leaves the optimistic order in place until the command answers")
    func defersReadDuringMove() async {
        let initial = three()
        let owner = owner(initial)
        let model = makeModel(owner)
        await model.load()
        let first = Fixtures.loginID
        let second = Fixtures.secondLoginID
        let last = thirdID
        let saved = Locked(false)
        owner.script {
            $0.credentials = {
                if saved.value {
                    return CredentialsList(credentials: [
                        Fixtures.account(second, name: "Team", provider: .codex, position: 1),
                        Fixtures.account(first, name: "Personal", position: 2),
                        Fixtures.account(last, name: "Updated", provider: .grok, position: 3),
                    ], asOfSeq: 12)
                }
                return CredentialsList(credentials: initial, asOfSeq: 11)
            }
            $0.reorderCredentials = { _, key in
                await model.load()
                await MainActor.run {
                    #expect(model.rows.map(\.id) == [second, first, last])
                    #expect(model.rows.map(\.name).last == "Grok, Work")
                }
                saved.update { $0 = true }
                return .completed(nil, key: key.value, command: .reorderCredentials)
            }
        }
        await model.moveDown(first)
        #expect(model.rows.map(\.name) == ["Codex, Team", "Claude, Personal", "Grok, Updated"])
        #expect(owner.calls.filter { $0.operation == .listCredentials }.count == 2)
        // Release the scripted closure's reference to the model.
        saveReorders(owner)
    }

    @Test("only an unanswered reorder of the same list keeps its command key")
    func retryKey() async {
        let owner = owner(three())
        let model = makeModel(owner)
        await model.load()
        owner.script { $0.reorderCredentials = { _, _ in throw URLError(.timedOut) } }

        let first = Fixtures.loginID
        await model.moveDown(first)
        await model.moveDown(first)
        await model.moveUp(thirdID)
        let calls = owner.calls.filter { $0.operation == .reorderCredentials }
        #expect(calls.count == 3)
        #expect(calls.first?.key != nil)
        #expect(calls.map(\.key).prefix(2).allSatisfy { $0 == calls.first?.key })
        #expect(calls.last?.key != calls.first?.key)
    }

    @Test("an optimistic reorder keeps each row's state and a 422 restores the old order")
    func rollsBackInvalidOrder() async {
        let first = Fixtures.loginID
        let second = Fixtures.secondLoginID
        let owner = owner([
            Fixtures.account(first, name: "Personal", state: .signedOut, position: 1),
            Fixtures.account(second, name: "Team", provider: .codex, since: now, position: 2),
            Fixtures.account(thirdID, name: "Key", provider: .openrouter, kind: .apiToken, position: 3),
        ])
        let model = makeModel(owner)
        await model.load()
        let original = model.rows
        let sent = Locked(false)
        owner.script {
            $0.reorderCredentials = { _, _ in
                sent.update { $0 = true }
                await MainActor.run {
                    #expect(model.rows.map(\.id) == [second, first, thirdID])
                    #expect(model.rows.map(\.state) == ["At its limit", "Signed out", "Not used for work yet"])
                    #expect(!model.canMoveDown(second))
                }
                throw TransportError(code: .invalid, message: "The order must name each credential.")
            }
        }
        await model.moveUp(second)
        #expect(sent.value)
        #expect(ordersSent(by: owner) == [order(second, first, thirdID)])
        #expect(model.rows == original)
        #expect(model.reorderFailure == "The list changed. Try again.")
        #expect(model.canMoveUp(second))

        saveReorders(owner)
        await model.moveUp(second)
        #expect(model.reorderFailure == nil)
        #expect(model.rows.map(\.id) == [second, first, thirdID])
    }

    @Test("opening the tab reads the order and seats without writing")
    func onlyReadsOnLoad() async {
        let owner = owner(three())
        let model = makeModel(owner)
        await model.load()
        let operations = Set(owner.calls.map(\.operation))
        #expect(operations.isSubset(of: [.listCredentials, .listSeats]))
    }

    // MARK: failures, positions, staying current

    @Test("the position noted is the lowest of the two reads")
    func notesLowestPosition() async {
        let reads = Locked<[Int]>([])
        let model = makeModel(owner(three(), asOfSeq: 20), reads: reads)
        await model.load()
        #expect(reads.value == [20])
    }

    @Test("a read that cannot reach the server shows one plain line and keeps the rows already shown")
    func cannotReach() async {
        let owner = owner(three())
        let model = makeModel(owner)
        await model.load()
        owner.script { $0.credentials = { throw URLError(.cannotConnectToHost) } }
        await model.load()
        #expect(model.state == .failed(.cannotReach))
        #expect(model.rows.count == 3)
    }

    @Test("a 401 shows the signed-out state")
    func signedOut() async {
        let owner = FakeOwnerAPI()
        owner.script { $0.credentials = { throw ShellFixtures.unauthenticated() } }
        let model = makeModel(owner)
        await model.load()
        #expect(model.state == .signedOut)
    }

    @Test("an event from the tail reads the order again")
    func readsAgainOnEvents() async {
        let owner = owner(three())
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
        let model = HandoffModel(api: owner, noteRead: { feed.noteRead(asOfSeq: $0) }, now: { now })
        model.attach(to: feed)
        await model.load()
        #expect(model.rows.count == 3)
        owner.script {
            $0.credentials = {
                CredentialsList(credentials: [Fixtures.account(Fixtures.loginID, name: "Only", position: 1)], asOfSeq: 30)
            }
        }
        batches.update { $0.append(EventsPage(events: [ShellFixtures.event(seq: 30)], nextAfterSeq: 30)) }
        #expect(await ShellFixtures.eventually { model.rows.map(\.name) == ["Claude, Only"] })
        model.detach()
        feed.stop()
    }

    // MARK: the screen

    @Test("the tab draws empty, with rows, with the eight sentences, and failed, light and dark")
    func renders() async {
        let loaded = makeModel(owner(three(), seats: [
            Fixtures.runningSeat(Fixtures.builderID, name: "A", credential: Fixtures.loginID)
        ]))
        await loaded.load()
        #expect(Fixtures.draws(HandoffContent(model: loaded), height: 760))
        #expect(Fixtures.draws(HandoffContent(model: loaded).environment(\.colorScheme, .dark), height: 760))
        let empty = makeModel(owner([]))
        await empty.load()
        #expect(Fixtures.draws(HandoffContent(model: empty)))
        let failing = FakeOwnerAPI()
        failing.script { $0.credentials = { throw URLError(.timedOut) } }
        let failed = makeModel(failing)
        await failed.load()
        #expect(Fixtures.draws(HandoffContent(model: failed)))
    }

    @Test("the tab is built with no arguments and draws inside the shell's context")
    func zeroArguments() async {
        let rig = ShellRig()
        rig.scriptSignIn(ownerExists: true)
        rig.runtime.fakeSessions.token.value = "stored-made-up-token"
        let model = rig.makeModel()
        await model.start()
        let context = model.screens!
        #expect(Fixtures.draws(HandoffView().environment(context)))
    }
}
