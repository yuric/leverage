import Foundation
import LeverageKit
import LeverageTestSupport
import SwiftUI
import Testing

@testable import LeverageApp

private typealias Fixtures = AgentFixtures

/// The Handoff tab's rows (HM-34 to HM-37): one list of every account, in the
/// order the server gives, numbered 1 to n, each naming the account it hands
/// off to and the last handing off to nobody. Names only; nothing reorders.
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
            Fixtures.account(thirdID, name: "Key", provider: .claudeApi, kind: .apiToken, position: 2),
        ]))
        await model.load()
        #expect(model.rows.map(\.name) == ["Claude, Personal", "Claude API, Key"])
        #expect(model.rows.first?.handsOff == "Hands off to Claude API, Key")
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
        for row in model.rows {
            for line in [row.name, row.state, row.handsOff, "\(row.number)"] {
                #expect(!line.contains("@") && !line.contains("made up") && !line.contains("…abcd"), "\(line)")
                #expect(BannedTerms.found(in: line).isEmpty, "\(line)")
            }
        }
    }

    // MARK: no way to reorder (HM-37)

    @Test("the tab's sources have no button, drag, move or reorder control")
    func nothingReorders() throws {
        let folder = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/LeverageApp/Handoff")
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(files.count >= 3)
        for file in files {
            let code = LiteralScanner.code(of: try String(contentsOf: file, encoding: .utf8))
            for forbidden in [
                "Button", "onMove", "onDrag", "onDrop", "draggable", "dropDestination", "EditButton", "Toggle", "moveUp",
                "moveDown", "reorder", "Stepper", "Picker",
            ] {
                #expect(!code.contains(forbidden), "\(file.lastPathComponent) has \(forbidden)")
            }
        }
    }

    @Test("the model has no way to write: the tab only reads")
    func onlyReads() async {
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
