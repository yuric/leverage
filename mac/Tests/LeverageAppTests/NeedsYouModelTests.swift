import Foundation
import LeverageKit
import LeverageTestSupport
import SwiftUI
import Testing

@testable import LeverageApp

private typealias Fixtures = NeedsYouFixtures

@MainActor
@Suite("NeedsYouModel")
struct NeedsYouModelTests {
    private func makeModel(
        _ owner: FakeOwnerAPI, reads: Locked<[Int]> = Locked([]), opened: Locked<[UUID]> = Locked([])
    ) -> NeedsYouModel {
        NeedsYouModel(
            api: owner, noteRead: { seq in reads.update { $0.append(seq) } },
            openTask: { id in opened.update { $0.append(id) } }, timing: .quick)
    }

    private func owner(_ items: [InboxItem]) -> FakeOwnerAPI {
        Fixtures.owner(open: Locked(items))
    }

    // MARK: the three items, with their words (HM-24)

    @Test("a new screen is loading and shows nothing")
    func startsLoading() {
        let model = makeModel(FakeOwnerAPI())
        #expect(model.state == .loading)
        #expect(model.rows.isEmpty)
    }

    @Test("with nothing open the screen is loaded and empty, and the empty sentence is the PRD's")
    func empty() async {
        let model = makeModel(owner([]))
        await model.load()
        #expect(model.state == .loaded)
        #expect(model.rows.isEmpty)
        #expect(NeedsYouCopy.empty.text == "Nothing needs you right now.")
    }

    @Test("Account signed out: the account named, the task, and one button, Sign in again")
    func signedOut() async {
        let model = makeModel(owner([Fixtures.signedOut(seq: 5)]))
        await model.load()
        let row = try? #require(model.rows.first)
        #expect(row?.heading == "Claude, Personal is signed out")
        #expect(
            row?.body == "Fix the totals on the invoice page stopped because Claude, Personal is signed out and no other account can take over. Sign in again to continue.")
        #expect(row?.buttons.map(\.label) == ["Sign in again"])
        #expect(row?.buttons.map(\.action) == [.signInAgain])
    }

    @Test("Limit with no reset time: says what to do, and has no button")
    func limitWithNoResetTime() async {
        let model = makeModel(owner([Fixtures.limit(seq: 6)]))
        await model.load()
        let row = try? #require(model.rows.first)
        #expect(row?.heading == "Claude, Personal is at its limit")
        #expect(
            row?.body == "Fix the totals on the invoice page is waiting. Claude did not say when Claude, Personal is available again. When it is, choose Verify on Claude, Personal in Credentials and the task continues. If the agent's time on the task runs out first, the task goes back to waiting for any agent.")
        #expect(row?.buttons.isEmpty == true)
    }

    @Test("Past the round limit: how many times it was sent back, and three buttons")
    func pastRoundLimit() async {
        let model = makeModel(owner([Fixtures.pastRound(seq: 7)]))
        await model.load()
        let row = try? #require(model.rows.first)
        #expect(row?.heading == "Fix the totals on the invoice page was sent back 3 times")
        #expect(row?.buttons.map(\.label) == ["Let it try once more", "Change the task", "Cancel task"])
        #expect(row?.buttons.map(\.action) == [.allowAnotherTry, .changeTask, .cancelTask])
    }

    @Test("a button is offered only when the item's own choices include it")
    func buttonsFollowChoices() async {
        let model = makeModel(owner([Fixtures.item(.pastRoundLimit, seq: 7, choices: [.cancel])]))
        await model.load()
        #expect(model.rows.first?.buttons.map(\.action) == [.cancelTask])
    }

    @Test("an item of a kind that cannot open yet is one plain line with no button")
    func unknownKind() async {
        let model = makeModel(owner([Fixtures.item(.approval, seq: 8)]))
        await model.load()
        let row = try? #require(model.rows.first)
        #expect(row?.buttons.isEmpty == true)
        #expect(row?.kind == .approval)
        #expect(row?.heading == "Fix the totals on the invoice page needs you, and leverage cannot open this kind of item yet.")
        #expect(row?.body == "")
    }

    @Test("rows are in the order the items opened, and no sentence carries an email or a banned word")
    func orderAndWords() async {
        let model = makeModel(owner([
            Fixtures.pastRound(seq: 9), Fixtures.signedOut(seq: 4), Fixtures.limit(seq: 6),
            Fixtures.item(.approval, seq: 8),
        ]))
        await model.load()
        #expect(model.rows.map(\.kind) == [.accountSignedOut, .limitWithNoResetTime, .approval, .pastRoundLimit])
        for row in model.rows {
            let text = ([row.heading, row.body] + row.buttons.map(\.label)).joined(separator: " ")
            #expect(!text.contains(Fixtures.madeUpEmail), "\(text)")
            #expect(!text.contains("@"), "\(text)")
            #expect(BannedTerms.found(in: text).isEmpty, "\(text)")
        }
    }

    @Test("a task the board does not know is named plainly, not by an id")
    func unknownTask() async {
        let missing = UUID()
        let model = makeModel(owner([Fixtures.pastRound(seq: 3, task: missing)]))
        await model.load()
        #expect(model.rows.first?.heading == "A task was sent back 3 times")
        #expect(!(model.rows.first?.heading.contains(missing.uuidString) ?? true))
    }

    // MARK: reading

    @Test("the board and the credentials are read before the inbox, and the lower position is noted")
    func readOrder() async {
        let reads = Locked<[Int]>([])
        let owner = owner([Fixtures.signedOut(seq: 5)])
        let model = makeModel(owner, reads: reads)
        await model.load()
        #expect(owner.calls.map(\.operation) == [.getBoard, .listCredentials, .listInbox])
        #expect(reads.value == [30])
    }

    @Test("it asks for every open item, with no position and no wait")
    func asksForAll() async {
        let seen = Locked<[(Int?, Int?)]>([])
        let owner = owner([])
        owner.script {
            $0.listInbox = { after, wait in
                seen.update { $0.append((after, wait)) }
                return Fixtures.page([])
            }
        }
        await makeModel(owner).load()
        #expect(seen.value.count == 1)
        #expect(seen.value.first?.0 == nil && seen.value.first?.1 == nil)
    }

    @Test("a read that cannot reach the server keeps the rows shown before and says so in one line")
    func cannotReach() async {
        let owner = owner([Fixtures.signedOut(seq: 5)])
        let model = makeModel(owner)
        await model.load()
        owner.script { $0.listInbox = { _, _ in throw URLError(.notConnectedToInternet) } }
        await model.load()
        #expect(model.state == .failed(.cannotReach))
        #expect(model.rows.count == 1)
    }

    @Test("a 401 shows the signed-out state")
    func unauthenticated() async {
        let owner = owner([])
        owner.script { $0.listInbox = { _, _ in throw ShellFixtures.unauthenticated() } }
        let model = makeModel(owner)
        await model.load()
        #expect(model.state == .signedOut)
    }

    @Test("names that cannot be read leave the item shown with plain fallbacks")
    func namesFail() async {
        let owner = owner([Fixtures.signedOut(seq: 5)])
        owner.script { $0.board = { throw URLError(.timedOut) } }
        let model = makeModel(owner)
        await model.load()
        #expect(model.rows.first?.heading == "An account is signed out")
    }

    @Test("an event from the tail reads again, and a settled item leaves the list")
    func readsAgainOnEvents() async {
        let open = Locked([Fixtures.signedOut(seq: 5)])
        let owner = Fixtures.owner(open: open)
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
        let model = NeedsYouModel(
            api: owner, noteRead: { feed.noteRead(asOfSeq: $0) }, openTask: { _ in }, timing: .quick)
        model.attach(to: feed)
        await model.load()
        #expect(model.rows.count == 1)
        open.value = []
        batches.update { $0.append(EventsPage(events: [ShellFixtures.event(seq: 40)], nextAfterSeq: 40)) }
        #expect(await ShellFixtures.eventually { model.rows.isEmpty })
        model.detach()
        feed.stop()
    }

    // MARK: Sign in again follows the helper request to its end

    @Test("Sign in again sends sign_in_again for the account, shows the waiting line, follows the request, reads again")
    func signInAgain() async throws {
        let owner = owner([Fixtures.signedOut(seq: 5)])
        let request = Fixtures.requestID
        let asked = Locked(0)
        let sawWaiting = Locked(false)
        let box = Locked<NeedsYouModel?>(nil)
        owner.script {
            $0.signInAgain = { _, key in AgentFixtures.plain(.signInAgain, key: key, helperRequest: request) }
            $0.helperRequest = { _, _, _ in
                let n = asked.update { $0 += 1; return $0 }
                if n == 1 {
                    return AgentFixtures.request(request, kind: .openSignIn, state: .pickedUp, updated: 1, credential: Fixtures.credentialID)
                }
                await MainActor.run {
                    if let model = box.value, let id = model.rows.first?.id, model.isWaitingForSignIn(id) { sawWaiting.value = true }
                }
                return AgentFixtures.request(
                    request, kind: .openSignIn, state: .finished, result: AgentFixtures.finished(), updated: 2,
                    credential: Fixtures.credentialID)
            }
        }
        let model = makeModel(owner)
        box.value = model
        await model.load()
        let id = try #require(model.rows.first?.id)
        owner.forgetCalls()
        await model.perform(.signInAgain, on: id)
        let sent = Fixtures.calls(owner, .signInAgain)
        #expect(sent.count == 1)
        #expect(sent.first?.path["id"] == Fixtures.credentialID.contractString)
        #expect(sent.first?.key != nil)
        #expect(asked.value == 2)
        #expect(sawWaiting.value)
        #expect(!model.isWaitingForSignIn(id))
        #expect(model.failure(for: id) == nil)
        #expect(Fixtures.calls(owner, .listInbox).count == 1)
        #expect(NeedsYouCopy.signInWaiting.text == "Waiting for you to sign in in the window that opened")
    }

    @Test("a sign-in that fails says which tool and what it did not do, in one line on that row")
    func signInFails() async throws {
        let owner = owner([Fixtures.signedOut(seq: 5)])
        let request = Fixtures.requestID
        owner.script {
            $0.signInAgain = { _, key in AgentFixtures.plain(.signInAgain, key: key, helperRequest: request) }
            $0.helperRequest = { _, _, _ in
                AgentFixtures.request(
                    request, kind: .openSignIn, state: .failed,
                    progress: [AgentFixtures.progress(.signedIn, .failed, failure: .notSignedIn)],
                    result: AgentFixtures.finished(.failed, failing: [HelperCheckResult(check: .signedIn, passed: false, failure: .notSignedIn)]),
                    credential: Fixtures.credentialID)
            }
        }
        let model = makeModel(owner)
        await model.load()
        let id = try #require(model.rows.first?.id)
        await model.perform(.signInAgain, on: id)
        #expect(model.failure(for: id) == "Claude Code is not signed in.")
        #expect(!model.isWaitingForSignIn(id))
    }

    @Test("Sign in again after the network failed uses the same key; after an answer a new one")
    func signInKeys() async throws {
        let owner = owner([Fixtures.signedOut(seq: 5)])
        let request = Fixtures.requestID
        let attempts = Locked(0)
        owner.script {
            $0.signInAgain = { _, key in
                if attempts.update({ $0 += 1; return $0 }) == 1 { throw URLError(.timedOut) }
                return AgentFixtures.plain(.signInAgain, key: key, helperRequest: request)
            }
            $0.helperRequest = { _, _, _ in
                AgentFixtures.request(request, kind: .openSignIn, state: .finished, result: AgentFixtures.finished())
            }
        }
        let model = makeModel(owner)
        await model.load()
        let id = try #require(model.rows.first?.id)
        await model.perform(.signInAgain, on: id)
        #expect(model.failure(for: id) == ShellCopy.cannotReach.text)
        await model.perform(.signInAgain, on: id)
        await model.perform(.signInAgain, on: id)
        let keys = Fixtures.calls(owner, .signInAgain).map(\.key)
        #expect(keys.count == 3 && keys[0] == keys[1] && keys[1] != keys[2])
    }

    @Test("a refused Sign in again shows the sentence for its code")
    func signInRefused() async throws {
        let owner = owner([Fixtures.signedOut(seq: 5)])
        let refusal = Refusal(code: .forbidden, ruleID: nil, reason: nil)
        owner.script { $0.signInAgain = { _, key in .refused(refusal, key: key.value, command: .signInAgain) } }
        let model = makeModel(owner)
        await model.load()
        let id = try #require(model.rows.first?.id)
        await model.perform(.signInAgain, on: id)
        #expect(model.failure(for: id) == ShellCopy.refusalForbidden.text)
    }

    // MARK: the round limit's three choices

    @Test("Let it try once more sends allow_another_round for the task, with a key kept until the server answers")
    func allowAnotherRound() async throws {
        let owner = owner([Fixtures.pastRound(seq: 7)])
        let attempts = Locked(0)
        owner.script {
            $0.allowAnotherRound = { _, key in
                if attempts.update({ $0 += 1; return $0 }) == 1 { throw URLError(.timedOut) }
                return AgentFixtures.plain(.allowAnotherRound, key: key)
            }
        }
        let model = makeModel(owner)
        await model.load()
        let id = try #require(model.rows.first?.id)
        await model.perform(.allowAnotherTry, on: id)
        #expect(model.failure(for: id) == ShellCopy.cannotReach.text)
        await model.perform(.allowAnotherTry, on: id)
        await model.perform(.allowAnotherTry, on: id)
        let sent = Fixtures.calls(owner, .allowAnotherRound)
        #expect(sent.count == 3)
        #expect(sent.allSatisfy { $0.path["id"] == Fixtures.taskID.contractString })
        #expect(sent[0].key == sent[1].key && sent[1].key != sent[2].key)
        #expect(model.failure(for: id) == nil)
    }

    @Test("Cancel task asks first and sends nothing; after the owner confirms it sends cancel_task")
    func cancelTask() async throws {
        let owner = owner([Fixtures.pastRound(seq: 7)])
        owner.script { $0.cancelTask = { _, key in AgentFixtures.plain(.cancel, key: key) } }
        let model = makeModel(owner)
        await model.load()
        let id = try #require(model.rows.first?.id)
        await model.perform(.cancelTask, on: id)
        #expect(model.confirmingCancel == id)
        #expect(Fixtures.calls(owner, .cancelTask).isEmpty)
        model.dismissCancel()
        #expect(model.confirmingCancel == nil)
        #expect(Fixtures.calls(owner, .cancelTask).isEmpty)
        await model.perform(.cancelTask, on: id)
        await model.confirmCancel()
        let sent = Fixtures.calls(owner, .cancelTask)
        #expect(sent.count == 1)
        #expect(sent.first?.path["id"] == Fixtures.taskID.contractString)
        #expect(sent.first?.key != nil)
        #expect(model.confirmingCancel == nil)
    }

    @Test("Change the task opens the task's page and sends nothing")
    func changeTask() async throws {
        let opened = Locked<[UUID]>([])
        let owner = owner([Fixtures.pastRound(seq: 7)])
        let model = makeModel(owner, opened: opened)
        await model.load()
        let id = try #require(model.rows.first?.id)
        owner.forgetCalls()
        await model.perform(.changeTask, on: id)
        #expect(opened.value == [Fixtures.taskID])
        #expect(owner.calls.isEmpty)
    }

    @Test("a button the row does not have sends nothing")
    func buttonNotOnRow() async throws {
        let owner = owner([Fixtures.signedOut(seq: 5)])
        let model = makeModel(owner)
        await model.load()
        let id = try #require(model.rows.first?.id)
        owner.forgetCalls()
        await model.perform(.cancelTask, on: id)
        await model.perform(.allowAnotherTry, on: UUID())
        #expect(owner.calls.isEmpty)
        #expect(model.confirmingCancel == nil)
    }
}
