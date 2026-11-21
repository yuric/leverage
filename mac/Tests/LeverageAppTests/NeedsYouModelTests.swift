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
        _ owner: FakeOwnerAPI, reads: Locked<[Int]> = Locked([]), opened: Locked<[UUID]> = Locked([]),
        agents: Locked<Int> = Locked(0), locale: Locale = Locale(identifier: "en_US")
    ) -> NeedsYouModel {
        NeedsYouModel(
            api: owner, noteRead: { seq in reads.update { $0.append(seq) } },
            openTask: { id in opened.update { $0.append(id) } }, openAgents: { agents.update { $0 += 1 } },
            timing: .quick, locale: locale)
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

    @Test("an approval missing its action is one plain line with no button")
    func unknownKind() async {
        let model = makeModel(owner([Fixtures.item(.approval, seq: 8)]))
        await model.load()
        let row = try? #require(model.rows.first)
        #expect(row?.buttons.isEmpty == true)
        #expect(row?.kind == .approval)
        #expect(row?.heading == "An action needs your approval")
        #expect(row?.body == "The details could not be read.")
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

    // MARK: the five items of the rule checks (RM-1, contract: needs_you.json)

    private func ruleModel(
        _ items: [InboxItem], checks: [RuleCheckRow] = [Fixtures.check()], opened: Locked<[UUID]> = Locked([]),
        agents: Locked<Int> = Locked(0)
    ) -> (NeedsYouModel, FakeOwnerAPI) {
        let owner = Fixtures.ruleOwner(open: Locked(items), checks: checks)
        return (makeModel(owner, opened: opened, agents: agents), owner)
    }

    @Test("the five kinds are the ones that get a row, and each has exactly the choices the contract lists")
    func fiveKindsWithTheirChoices() async {
        let expected: [(NeedsYouItem, [InboxChoice], [NeedsYouButton.Action], [String])] = [
            (.refusedForEveryAgent, [.editContract, .overrideOnce, .turnRuleOff, .cancel],
             [.changeTask, .letThroughOnce, .turnRuleOff, .cancelTask],
             ["Change the task", "Let it through once", "Turn the rule off", "Cancel task"]),
            (.checkPastRerunLimit, [.overrideOnce, .editContract, .cancel],
             [.letThroughOnce, .changeTask, .cancelTask], ["Let it through once", "Change the task", "Cancel task"]),
            (.checkCouldNotRun, [.runAgain, .overrideOnce, .turnRuleOff],
             [.runAgain, .letThroughOnce, .turnRuleOff], ["Run it again", "Let it through once", "Turn the rule off"]),
            (.noReviewerEligible, [.connectSeat, .turnRuleOff],
             [.connectAgent, .turnRuleOff], ["Connect an agent", "Turn the rule off"]),
        ]
        for (kind, choices, actions, labels) in expected {
            #expect(NeedsYouWords.isShown(kind), "\(kind)")
            #expect(Fixtures.defaultChoices(kind) == choices, "the fixture keeps the contract's order: \(kind)")
            let (model, _) = ruleModel([Fixtures.ruleItem(kind, seq: 5)])
            await model.load()
            #expect(model.rows.first?.buttons.map(\.action) == actions, "\(kind)")
            #expect(model.rows.first?.buttons.map(\.label) == labels, "\(kind)")
        }
        #expect(NeedsYouWords.isShown(.orchestratorOffline))
    }

    @Test("a button is offered only when the item's own choices include it")
    func ruleButtonsFollowChoices() async {
        let (model, _) = ruleModel([Fixtures.ruleItem(.checkCouldNotRun, seq: 5, choices: [.runAgain])])
        await model.load()
        #expect(model.rows.first?.buttons.map(\.action) == [.runAgain])
    }

    @Test("Every agent was turned away: the heading, the task, the rule's name and the reason, all as data")
    func refusedRow() async {
        let (model, owner) = ruleModel([Fixtures.ruleItem(.refusedForEveryAgent, seq: 5)])
        await model.load()
        let row = try? #require(model.rows.first)
        #expect(row?.heading == "Every agent was turned away")
        #expect(row?.body.contains(Fixtures.taskTitle) == true)
        #expect(row?.ruleName == Fixtures.ruleName)
        #expect(row?.reason == Fixtures.reason)
        #expect(Fixtures.calls(owner, .getTask).count == 1)
    }

    @Test("Checked too many times and A check could not run have their own words, the rule and the reason")
    func rerunAndCouldNotRunRows() async {
        let (model, _) = ruleModel([
            Fixtures.ruleItem(.checkPastRerunLimit, seq: 5), Fixtures.ruleItem(.checkCouldNotRun, seq: 6),
        ])
        await model.load()
        #expect(model.rows.map(\.heading) == ["Checked too many times", "A check could not run"])
        for row in model.rows {
            #expect(row.body.contains(Fixtures.taskTitle))
            #expect(row.ruleName == Fixtures.ruleName)
            #expect(row.reason == Fixtures.reason)
        }
        // Review finding 24: the checks ran and did not pass; they did not go unanswered.
        #expect(model.rows.first?.body == "\(Fixtures.taskTitle) was checked as many times as the rule allows, and it "
            + "did not pass. It waits until you choose what happens next.")
    }

    @Test("No agent may review this: the rule is read from the rules list, and there is no reason")
    func noReviewerRow() async {
        let (model, owner) = ruleModel([
            Fixtures.ruleItem(.noReviewerEligible, seq: 5, rule: Fixtures.providerRuleID, check: nil)
        ])
        await model.load()
        let row = try? #require(model.rows.first)
        #expect(row?.heading == "No agent may review this")
        #expect(row?.body.contains(Fixtures.taskTitle) == true)
        #expect(row?.ruleName == Fixtures.providerRuleName)
        #expect(row?.reason == nil)
        #expect(Fixtures.calls(owner, .getTask).isEmpty, "there is no check to read")
    }

    @Test("the rule and the reason are read once for each task, and not at all when no such item is open")
    func readsOnlyWhatItNeeds() async {
        let (none, plain) = ruleModel([Fixtures.signedOut(seq: 5)])
        await none.load()
        #expect(plain.calls.map(\.operation) == [.getBoard, .listCredentials, .listInbox])

        let (two, owner) = ruleModel([
            Fixtures.ruleItem(.checkCouldNotRun, seq: 5), Fixtures.ruleItem(.checkPastRerunLimit, seq: 6),
        ])
        await two.load()
        #expect(Fixtures.calls(owner, .getTask).count == 1)
    }

    @Test("a rule or a reason that cannot be read leaves the row without them, and with its buttons")
    func ruleReadsFail() async {
        let (model, owner) = ruleModel([Fixtures.ruleItem(.checkCouldNotRun, seq: 5)])
        owner.script {
            $0.task = { _ in throw URLError(.timedOut) }
            $0.listRules = { throw URLError(.timedOut) }
        }
        await model.load()
        #expect(model.state == .loaded)
        let row = try? #require(model.rows.first)
        #expect(row?.heading == "A check could not run")
        #expect(row?.ruleName == nil)
        #expect(row?.reason == nil)
        #expect(row?.buttons.count == 3)
    }

    @Test("a check with no reason, or an empty one, shows none")
    func noReason() async {
        let (model, _) = ruleModel(
            [Fixtures.ruleItem(.checkCouldNotRun, seq: 5)], checks: [Fixtures.check(result: .error, reason: "  ")])
        await model.load()
        #expect(model.rows.first?.ruleName == Fixtures.ruleName)
        #expect(model.rows.first?.reason == nil)
    }

    @Test("the offline item is one plain line with no button, and says how many checks are waiting now")
    func offlineRow() async {
        let open = Locked([Fixtures.offline(seq: 5, waiting: 3)])
        let owner = Fixtures.ruleOwner(open: open)
        let model = makeModel(owner)
        await model.load()
        let row = try? #require(model.rows.first)
        #expect(row?.kind == .orchestratorOffline)
        #expect(row?.heading == "The agent that checks tasks is offline")
        #expect(row?.body.hasPrefix("3 checks are waiting.") == true)
        #expect(row?.buttons.isEmpty == true)
        #expect(row?.taskID == nil)
        #expect(Fixtures.calls(owner, .getTask).isEmpty)

        // The count is the one the server reads each time, not the one the item opened with.
        open.value = [Fixtures.offline(seq: 5, id: open.value[0].id, waiting: 1)]
        await model.load()
        #expect(model.rows.first?.body.hasPrefix("1 check is waiting.") == true)
        open.value = [Fixtures.offline(seq: 5, id: open.value[0].id, waiting: 12)]
        await model.load()
        #expect(model.rows.first?.body.hasPrefix("12 checks are waiting.") == true)
    }

    @Test("the offline item with no count says so without a number, and names the account that is the cause")
    func offlineWithoutCountAndWithAccount() async {
        let (model, _) = ruleModel([Fixtures.offline(seq: 5, waiting: nil, credential: Fixtures.credentialID)])
        await model.load()
        let body = model.rows.first?.body ?? ""
        #expect(!body.contains("0"))
        #expect(body.hasPrefix("Checks wait until the agent is back"))
        // Review finding 22: the account's state, not only its name (L401).
        #expect(body.contains("Claude, Personal is signed out. Look at it in Credentials."))
        #expect(!body.contains(Fixtures.madeUpEmail))
    }

    @Test("the offline item names the account's reset time when it is at its limit until a time (L401)")
    func offlineLimitedUntil() async {
        let until = Date().addingTimeInterval(3 * 3600)
        let credentials = CredentialsList(
            credentials: [
                CredentialWithReading(
                    credential: Credential(
                        id: Fixtures.credentialID, provider: .claude, name: "Personal", state: .active,
                        limitedUntil: until, limitedSince: Date().addingTimeInterval(-60), position: 1))
            ], asOfSeq: 31)
        let owner = Fixtures.owner(
            open: Locked([Fixtures.offline(seq: 5, credential: Fixtures.credentialID)]), credentials: credentials)
        owner.script { $0.systemHealth = { Self.health(.offline) } }
        let model = makeModel(owner)
        await model.load()
        let time = ResetTime.text(for: until, clock: .system)
        #expect(model.rows.first?.body.contains("Claude, Personal is at its limit until \(time). Look at it in Credentials.") == true)
    }

    @Test("the offline item with no agent set up to check says to connect one, not that it will be back")
    func offlineNotSetUp() async {
        let owner = Fixtures.ruleOwner(open: Locked([Fixtures.offline(seq: 5, waiting: 2)]))
        owner.script { $0.systemHealth = { Self.health(.notSetUp) } }
        let model = makeModel(owner)
        await model.load()
        #expect(model.rows.first?.body == "No agent is set up to check tasks. Connect one in Agents.")

        owner.script { $0.systemHealth = { Self.health(.offline) } }
        await model.load()
        #expect(model.rows.first?.body.hasPrefix("2 checks are waiting. They start on their own when the agent is back.") == true)
    }

    nonisolated private static func health(_ orchestrator: OrchestratorState) -> SystemHealth {
        SystemHealth(
            sweepLastRanAt: nil, sweepLate: false, helperLastReportedAt: nil, queuedHelperRequests: 0, readyTasks: 0,
            waitingReviews: 0, orchestrator: orchestrator)
    }

    @Test("every sentence of the five items is free of an email and of a banned word, filled in")
    func fiveItemsTidy() async {
        let (model, _) = ruleModel([
            Fixtures.ruleItem(.refusedForEveryAgent, seq: 1), Fixtures.ruleItem(.checkPastRerunLimit, seq: 2),
            Fixtures.ruleItem(.checkCouldNotRun, seq: 3), Fixtures.ruleItem(.noReviewerEligible, seq: 4),
            Fixtures.offline(seq: 5, credential: Fixtures.credentialID),
        ])
        await model.load()
        #expect(model.rows.count == 5)
        for row in model.rows {
            let text = ([row.heading, row.body] + row.buttons.map(\.label)).joined(separator: " ")
            #expect(!text.contains("@"), "\(text)")
            #expect(!text.contains("{"), "\(text)")
            #expect(BannedTerms.found(in: text).isEmpty, "\(text)")
        }
    }

    // MARK: the buttons of the five items

    @Test("Run it again sends rerun_check for the check the item names, then reads again")
    func runAgain() async throws {
        let (model, owner) = ruleModel([Fixtures.ruleItem(.checkCouldNotRun, seq: 5)])
        owner.script { $0.rerunCheck = { _, key in AgentFixtures.plain(.rerunCheck, key: key) } }
        await model.load()
        let id = try #require(model.rows.first?.id)
        owner.forgetCalls()
        await model.perform(.runAgain, on: id)
        let sent = Fixtures.calls(owner, .rerunCheck)
        #expect(sent.count == 1)
        #expect(sent.first?.path["id"] == Fixtures.checkID.contractString)
        #expect(Fixtures.calls(owner, .listInbox).count == 1)
    }

    @Test("Let it through once asks why first, sends nothing until there is a reason, and sends it as the owner wrote it")
    func letThroughOnce() async throws {
        let (model, owner) = ruleModel([Fixtures.ruleItem(.refusedForEveryAgent, seq: 5)])
        owner.script { $0.overrideCheck = { _, _, key in AgentFixtures.plain(.overrideCheck, key: key) } }
        await model.load()
        let id = try #require(model.rows.first?.id)
        owner.forgetCalls()
        await model.perform(.letThroughOnce, on: id)
        #expect(model.letThroughRow == id)
        #expect(Fixtures.calls(owner, .overrideCheck).isEmpty)
        #expect(!model.canLetThrough)
        model.letThroughReason = "   "
        #expect(!model.canLetThrough)
        await model.confirmLetThrough()
        #expect(Fixtures.calls(owner, .overrideCheck).isEmpty, "a blank reason sends nothing")
        model.letThroughReason = "  It is fine; the page is named in the details.  "
        #expect(model.canLetThrough)
        await model.confirmLetThrough()
        let sent = Fixtures.calls(owner, .overrideCheck)
        #expect(sent.count == 1)
        #expect(sent.first?.path["id"] == Fixtures.checkID.contractString)
        guard case .object(let fields)? = sent.first?.body else { Issue.record("no body"); return }
        #expect(fields["reason"] == .string("It is fine; the page is named in the details."))
        #expect(model.letThroughRow == nil)
        #expect(model.letThroughReason.isEmpty)
        #expect(Fixtures.calls(owner, .listInbox).count == 1)
    }

    @Test("Go back on the reason drops it and sends nothing")
    func letThroughDismissed() async throws {
        let (model, owner) = ruleModel([Fixtures.ruleItem(.checkPastRerunLimit, seq: 5)])
        await model.load()
        let id = try #require(model.rows.first?.id)
        await model.perform(.letThroughOnce, on: id)
        model.letThroughReason = "because"
        model.dismissLetThrough()
        #expect(model.letThroughRow == nil)
        #expect(model.letThroughReason.isEmpty)
        #expect(Fixtures.calls(owner, .overrideCheck).isEmpty)
    }

    @Test("a refused Let it through once leaves the reason in place, with one plain line on the row")
    func letThroughRefused() async throws {
        let (model, owner) = ruleModel([Fixtures.ruleItem(.checkCouldNotRun, seq: 5)])
        owner.script { $0.overrideCheck = { _, _, _ in throw URLError(.timedOut) } }
        await model.load()
        let id = try #require(model.rows.first?.id)
        await model.perform(.letThroughOnce, on: id)
        model.letThroughReason = "because"
        await model.confirmLetThrough()
        #expect(model.failure(for: id) == ShellCopy.cannotReach.text)
        #expect(model.letThroughReason == "because")
        #expect(model.letThroughRow == id)
    }

    @Test("Let it through once with no check named by the item sends nothing")
    func letThroughNeedsACheck() async throws {
        let (model, owner) = ruleModel([Fixtures.ruleItem(.refusedForEveryAgent, seq: 5, check: nil)])
        await model.load()
        let id = try #require(model.rows.first?.id)
        await model.perform(.letThroughOnce, on: id)
        #expect(model.letThroughRow == nil)
        #expect(Fixtures.calls(owner, .overrideCheck).isEmpty)
    }

    @Test("Turn the rule off asks first, and then sends disable_rule for the rule the item names")
    func turnRuleOff() async throws {
        let (model, owner) = ruleModel([Fixtures.ruleItem(.noReviewerEligible, seq: 5, rule: Fixtures.providerRuleID, check: nil)])
        owner.script { $0.disableRule = { _, key in AgentFixtures.plain(.disableRule, key: key) } }
        await model.load()
        let id = try #require(model.rows.first?.id)
        owner.forgetCalls()
        await model.perform(.turnRuleOff, on: id)
        #expect(model.confirmingTurnOff == id)
        #expect(Fixtures.calls(owner, .disableRule).isEmpty)
        model.dismissTurnOff()
        #expect(model.confirmingTurnOff == nil)
        await model.perform(.turnRuleOff, on: id)
        await model.confirmTurnOff()
        let sent = Fixtures.calls(owner, .disableRule)
        #expect(sent.count == 1)
        #expect(sent.first?.path["id"] == Fixtures.providerRuleID.contractString)
        #expect(model.confirmingTurnOff == nil)
        #expect(Fixtures.calls(owner, .listInbox).count == 1)
    }

    @Test("Change the task opens the task's page to edit; Connect an agent shows the Agents screen")
    func changeAndConnect() async throws {
        let opened = Locked<[UUID]>([])
        let agents = Locked(0)
        let (model, _) = ruleModel(
            [Fixtures.ruleItem(.refusedForEveryAgent, seq: 5), Fixtures.ruleItem(.noReviewerEligible, seq: 6)],
            opened: opened, agents: agents)
        await model.load()
        let refused = try #require(model.rows.first { $0.kind == .refusedForEveryAgent }?.id)
        let noReviewer = try #require(model.rows.first { $0.kind == .noReviewerEligible }?.id)
        await model.perform(.changeTask, on: refused)
        #expect(opened.value == [Fixtures.taskID])
        await model.perform(.connectAgent, on: noReviewer)
        #expect(agents.value == 1)
    }

    @Test("Cancel task on a check item asks first and then cancels the task")
    func cancelOnACheckItem() async throws {
        let (model, owner) = ruleModel([Fixtures.ruleItem(.checkPastRerunLimit, seq: 5)])
        owner.script { $0.cancelTask = { _, key in AgentFixtures.plain(.cancel, key: key) } }
        await model.load()
        let id = try #require(model.rows.first?.id)
        await model.perform(.cancelTask, on: id)
        #expect(model.confirmingCancel == id)
        await model.confirmCancel()
        #expect(Fixtures.calls(owner, .cancelTask).first?.path["id"] == Fixtures.taskID.contractString)
    }

    @Test("a button the row does not have sends nothing")
    func foreignButton() async throws {
        let (model, owner) = ruleModel([Fixtures.ruleItem(.noReviewerEligible, seq: 5, check: nil)])
        await model.load()
        let id = try #require(model.rows.first?.id)
        owner.forgetCalls()
        await model.perform(.runAgain, on: id)
        await model.perform(.letThroughOnce, on: id)
        #expect(model.letThroughRow == nil)
        #expect(owner.calls.isEmpty)
    }

    @Test("the five rows draw, light and dark, and with the reason and the confirmations open")
    func fiveRowsDraw() async throws {
        let (model, _) = ruleModel([
            Fixtures.ruleItem(.refusedForEveryAgent, seq: 1), Fixtures.ruleItem(.checkCouldNotRun, seq: 2),
            Fixtures.ruleItem(.noReviewerEligible, seq: 3, check: nil), Fixtures.offline(seq: 4),
        ])
        await model.load()
        let draw = { (dark: Bool) in
            AgentFixtures.draws(
                NeedsYouContent(model: model, notificationsAreOff: true).environment(\.colorScheme, dark ? .dark : .light))
        }
        #expect(draw(false))
        #expect(draw(true))
        let refused = try #require(model.rows.first { $0.kind == .refusedForEveryAgent }?.id)
        await model.perform(.letThroughOnce, on: refused)
        #expect(draw(false))
        let row = try #require(model.rows.first { $0.id == refused })
        #expect(AgentFixtures.draws(NeedsYouRowView(row: row, model: model), width: 520, height: 320))
        #expect(AgentFixtures.draws(NeedsYouRowView(row: row, model: model).environment(\.colorScheme, .dark), width: 520, height: 320))
        model.dismissLetThrough()
        let couldNot = try #require(model.rows.first { $0.kind == .checkCouldNotRun }?.id)
        await model.perform(.turnRuleOff, on: couldNot)
        #expect(draw(false))
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

    // Review: Antigravity has no sign-in command, so no window opens; the
    // owner signs in on this Mac and leverage continues on its own.
    @Test("while Sign in again waits for a Gemini account the row says to sign in to Antigravity, not to a window")
    func signInAgainGemini() async throws {
        let gemini = CredentialsList(credentials: [
            CredentialWithReading(credential: Credential(
                id: Fixtures.credentialID, provider: .gemini, name: "Work", state: .signedOut, position: 1))
        ], asOfSeq: 31)
        let owner = Fixtures.owner(open: Locked([Fixtures.signedOut(seq: 5)]), credentials: gemini)
        let request = Fixtures.requestID
        let lines = Locked<[String?]>([])
        let box = Locked<NeedsYouModel?>(nil)
        owner.script {
            $0.signInAgain = { _, key in AgentFixtures.plain(.signInAgain, key: key, helperRequest: request) }
            $0.helperRequest = { _, _, _ in
                let line = await MainActor.run { () -> String? in
                    guard let model = box.value, let id = model.rows.first?.id else { return nil }
                    return model.signInWaitingLine(id)
                }
                lines.update { $0.append(line) }
                return AgentFixtures.request(
                    request, kind: .openSignIn, state: .finished, result: AgentFixtures.finished(), updated: 2,
                    credential: Fixtures.credentialID)
            }
        }
        let model = makeModel(owner)
        box.value = model
        await model.load()
        let id = try #require(model.rows.first?.id)
        await model.perform(.signInAgain, on: id)
        #expect(lines.value == ["Sign in to Antigravity on this Mac. leverage continues on its own."])
        #expect(model.signInWaitingLine(id) == nil)
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

@MainActor
extension NeedsYouModelTests {
    nonisolated private static let questionID = UUID()
    nonisolated private static let actionID = UUID()
    nonisolated private static let secondActionID = UUID()
    nonisolated private static let projectID = UUID()
    nonisolated private static let criterionID = UUID()
    nonisolated private static let anotherCriterionID = UUID()
    nonisolated private static let reviewID = UUID()
    nonisolated private static let builderID = TaskScreenFixtures.builderID
    nonisolated private static let approverID = UUID()

    private func milestoneFive(
        _ kind: NeedsYouItem, blocking: Bool = false, started: Bool = false,
        checked: Bool = false, enabled: Bool = true, ownerApproved: Bool = false,
        approvalState: ActionState = .requested, description: String = "the release notes",
        locale: Locale = Locale(identifier: "en_US")
    ) -> (NeedsYouModel, FakeOwnerAPI, InboxItem) {
        let action = ["action_id": JSONValue.string(Self.actionID.contractString)]
        let choices: [InboxChoice]
        var facts: [String: JSONValue] = [:]
        switch kind {
        case .questionPassedOn:
            choices = [.answer]
            facts = ["question_id": .string(Self.questionID.contractString)]
        case .approval:
            choices = [.approve, .stop]
            facts = action
        case .stoppedAction:
            choices = [.waive, .returnForRework, .cancel, .overrideOnce]
            facts = action
            facts["any_action_started"] = .bool(started)
            facts["rule_check_id"] = checked ? .string(Fixtures.checkID.contractString) : .null
        case .unconfirmedAction:
            choices = [.offerAgain, .markDone, .waive, .cancel]
            facts = [
                "action_ids": .array([.string(Self.actionID.contractString), .string(Self.secondActionID.contractString)]),
                "approved_by_kind": .string(ownerApproved ? "owner" : "seat"),
                "approved_by_id": .string(Self.approverID.contractString),
                "builder_announced_start": .bool(started),
            ]
        case .accessRequest: choices = [.markAccessGranted, .cancel]
        case .taskBudgetReached: choices = [.raiseCap, .cancel]
        case .projectBudgetReached: choices = [.changeBudget, .resumeProject]
        default: preconditionFailure("Expected a milestone 5 item")
        }
        let project = kind == .projectBudgetReached
        let item = Fixtures.item(
            kind, seq: 50, task: project ? Self.projectID : Fixtures.taskID, choices: choices,
            facts: facts, about: project ? .project : .task)
        let owner = self.owner([item])
        let actionState: ActionState = switch kind {
        case .stoppedAction: .stopped
        case .unconfirmedAction: started ? .started : .approved
        default: approvalState
        }
        let page = TaskPage(
            task: TaskScreenFixtures.summary(.finishing, id: Fixtures.taskID, builder: Self.builderID),
            criteria: [
                TaskScreenFixtures.criterion("Keep the title", taskID: Fixtures.taskID, id: Self.criterionID),
                TaskScreenFixtures.criterion(
                    "Correct the totals", taskID: Fixtures.taskID, position: 2, id: Self.anotherCriterionID),
                TaskScreenFixtures.criterion(
                    "Review the work", taskID: Fixtures.taskID, position: 3, kind: .review, id: Self.reviewID),
            ],
            actions: [
                OutwardAction(
                    id: Self.actionID, taskID: Fixtures.taskID, kind: .publish,
                    description: description, state: actionState),
                OutwardAction(
                    id: Self.secondActionID, taskID: Fixtures.taskID, kind: .send,
                    description: "the invoice", state: .approved, approvedByKind: .owner, position: 2),
            ],
            questions: [
                Question(
                    id: Self.questionID, taskID: Fixtures.taskID, askingSeatID: Self.builderID,
                    text: "Which rounding rule?", assumption: "round half up", blocking: blocking, outcome: .passedOn)
            ],
            names: [LogName(kind: .seat, id: Self.builderID, name: "Builder One")],
            reviewerSeatExists: true, asOfSeq: 51, ruleChecks: checked ? [Fixtures.check()] : [],
            anyActionStarted: started)
        owner.script {
            $0.task = { _ in page }
            $0.seats = {
                SeatsList(seats: [
                    Seat(id: Self.builderID, name: "Builder One", provider: .codex, role: .builder, enabled: enabled),
                    Seat(id: Self.approverID, name: "Review Desk", provider: .claude, role: .orchestrator),
                ], asOfSeq: 51)
            }
            $0.listProjects = {
                ProjectsList(projects: [Project(id: Self.projectID, name: "Invoices", goal: "Correct totals", briefVersion: 0)])
            }
            $0.answerQuestion = { _, _, key in TaskScreenFixtures.plain(.answerQuestion, key: key) }
            $0.approveAction = { _, key in TaskScreenFixtures.plain(.approveAction, key: key) }
            $0.stopAction = { _, key in TaskScreenFixtures.plain(.stopAction, key: key) }
            $0.waiveAction = { _, key in TaskScreenFixtures.plain(.waiveAction, key: key) }
            $0.returnForRework = { _, _, key in TaskScreenFixtures.plain(.returnForRework, key: key) }
            $0.overrideCheck = { _, _, key in TaskScreenFixtures.plain(.overrideCheck, key: key) }
            $0.offerTaskAgain = { _, key in TaskScreenFixtures.plain(.offerTaskAgain, key: key) }
            $0.markActionDone = { _, key in TaskScreenFixtures.plain(.markActionDone, key: key) }
            $0.grantAccess = { _, key in TaskScreenFixtures.plain(.grantAccess, key: key) }
            $0.cancelTask = { _, key in TaskScreenFixtures.plain(.cancel, key: key) }
            $0.changeTaskCap = { _, _, key in TaskScreenFixtures.plain(.changeTaskCap, key: key) }
            $0.changeBudget = { _, _, key in TaskScreenFixtures.plain(.changeBudget, key: key) }
            $0.resumeProject = { _, key in TaskScreenFixtures.plain(.resumeProject, key: key) }
        }
        return (makeModel(owner, locale: locale), owner, item)
    }

    private func expectCall(
        _ owner: FakeOwnerAPI, _ operation: ContractOperation, id: UUID, body: JSONValue? = nil
    ) {
        let call = Fixtures.calls(owner, operation).last
        #expect(call?.path == ["id": id.contractString])
        #expect(call?.key != nil)
        #expect(call?.body == body)
    }

    @Test("a question shows both answers, and Keep that sends the worker's assumption", arguments: [false, true])
    func milestoneQuestion(blocking: Bool) async throws {
        let (model, owner, item) = milestoneFive(.questionPassedOn, blocking: blocking)
        await model.load()
        let row = try #require(model.rows.first)
        #expect(row.heading == "Builder One asked while working on Fix the totals on the invoice page")
        #expect(row.body.contains("Which rounding rule?"))
        let line = blocking ? "It is waiting for your answer." : "It is assuming round half up and has kept working."
        #expect(row.body.contains(line))
        #expect(row.buttons.map(\.label) == ["Keep that", "Answer differently"])
        await model.perform(.keepAssumption, on: item.id)
        expectCall(owner, .answerQuestion, id: Self.questionID, body: .object(["answer": .string("round half up")]))
        await model.perform(.answerDifferently, on: item.id)
        model.promptText = "round to even"
        await model.confirmPrompt()
        expectCall(owner, .answerQuestion, id: Self.questionID, body: .object(["answer": .string("round to even")]))
        #expect(Fixtures.calls(owner, .answerQuestion).count == 2)
    }

    @Test("approval names the action and routes both choices to that action")
    func milestoneApproval() async throws {
        let (model, owner, item) = milestoneFive(.approval)
        await model.load()
        let row = try #require(model.rows.first)
        #expect(row.heading == "Publish the release notes?")
        #expect(row.body == "Fix the totals on the invoice page passed its review. Publishing cannot be undone.")
        #expect(row.buttons.map(\.label) == ["Approve", "Do not publish"])
        await model.perform(.approve, on: item.id)
        await model.perform(.stop, on: item.id)
        expectCall(owner, .approveAction, id: Self.actionID)
        expectCall(owner, .stopAction, id: Self.actionID)
    }

    @Test("an action sentence uses its verb once in the approval and unconfirmed item")
    func actionSentence() async {
        let (approval, _, _) = milestoneFive(.approval, description: "Publish the sample page.")
        await approval.load()
        #expect(approval.rows.first?.heading == "Publish the sample page?")

        let (unconfirmed, _, _) = milestoneFive(.unconfirmedAction, description: "Publish the sample page.")
        await unconfirmed.load()
        #expect(unconfirmed.rows.first?.body.contains("publish the sample page, approved") == true)
        #expect(unconfirmed.rows.first?.body.localizedCaseInsensitiveContains("publish publish") == false)
    }

    @Test("an unrefreshed approval item cannot approve an action the task now shows as stopped")
    func staleApprovalItem() async {
        let (model, owner, item) = milestoneFive(.approval, approvalState: .stopped)
        await model.load()
        #expect(model.rows.first?.buttons.isEmpty == true)
        await model.perform(.approve, on: item.id)
        #expect(Fixtures.calls(owner, .approveAction).isEmpty)
    }

    @Test("a stopped action never offers Approve and rework sends only the chosen build criteria")
    func milestoneStopped() async throws {
        let (model, owner, item) = milestoneFive(.stoppedAction, checked: true)
        await model.load()
        let row = try #require(model.rows.first)
        #expect(row.heading == "Publish was stopped")
        #expect(row.reason == Fixtures.reason)
        #expect(row.buttons.map(\.label) == ["Skip it", "Send the task back", "Cancel task", "Let it through once"])
        await model.perform(.approve, on: item.id)
        #expect(Fixtures.calls(owner, .approveAction).isEmpty)
        await model.perform(.returnForRework, on: item.id)
        model.selectedCriterionIDs = [Self.anotherCriterionID, Self.reviewID]
        await model.confirmPrompt()
        expectCall(owner, .returnForRework, id: Fixtures.taskID, body: .object([
            "criterion_ids": .array([.string(Self.anotherCriterionID.contractString)])
        ]))
        await model.perform(.letThroughOnce, on: item.id)
        model.letThroughReason = "I reviewed the changes."
        await model.confirmLetThrough()
        expectCall(owner, .overrideCheck, id: Fixtures.checkID, body: .object(["reason": .string("I reviewed the changes.")]))
        await model.perform(.waive(Self.actionID), on: item.id)
        expectCall(owner, .waiveAction, id: Self.actionID)
        await model.perform(.cancelTask, on: item.id)
        #expect(Fixtures.calls(owner, .cancelTask).isEmpty)
        await model.confirmCancel()
        expectCall(owner, .cancelTask, id: Fixtures.taskID)
    }

    @Test("a stopped action with a start and no failed check hides rework and the rule exception")
    func milestoneStoppedGuards() async throws {
        let (model, owner, item) = milestoneFive(.stoppedAction, started: true)
        await model.load()
        let row = try #require(model.rows.first)
        #expect(row.buttons.map(\.label) == ["Skip it", "Cancel task"])
        await model.perform(.returnForRework, on: item.id)
        model.selectedCriterionIDs = [Self.criterionID]
        await model.confirmPrompt()
        await model.perform(.letThroughOnce, on: item.id)
        model.letThroughReason = "I reviewed the changes."
        await model.confirmLetThrough()
        #expect(Fixtures.calls(owner, .returnForRework).isEmpty)
        #expect(Fixtures.calls(owner, .overrideCheck).isEmpty)
    }

    @Test("an unconfirmed item names the approver and start, and routes choices for each action", arguments: [false, true])
    func milestoneUnconfirmed(enabled: Bool) async throws {
        let (model, owner, item) = milestoneFive(
            .unconfirmedAction, started: enabled, enabled: enabled, ownerApproved: !enabled)
        await model.load()
        let row = try #require(model.rows.first)
        #expect(row.heading == "Did publishing happen?")
        #expect(row.body.contains("Builder One was to publish the release notes"))
        #expect(row.body.contains(enabled ? "approved by Review Desk" : "approved by you"))
        #expect(row.body.contains(enabled ? "after it said it had started" : "before it said it had started"))
        #expect(row.body.contains("the invoice"))
        #expect(row.buttons.contains { $0.label == "Ask Builder One again" } == enabled)
        await model.perform(.offerAgain, on: item.id)
        if enabled {
            expectCall(owner, .offerTaskAgain, id: Fixtures.taskID)
        } else {
            #expect(Fixtures.calls(owner, .offerTaskAgain).isEmpty)
        }
        await model.perform(.markDone(Self.secondActionID), on: item.id)
        await model.perform(.waive(Self.actionID), on: item.id)
        expectCall(owner, .markActionDone, id: Self.secondActionID)
        expectCall(owner, .waiveAction, id: Self.actionID)
        await model.perform(.cancelTask, on: item.id)
        await model.confirmCancel()
        expectCall(owner, .cancelTask, id: Fixtures.taskID)
    }

    @Test("granting access and cancelling use the task ID")
    func milestoneAccess() async throws {
        let (model, owner, item) = milestoneFive(.accessRequest)
        await model.load()
        let row = try #require(model.rows.first)
        #expect(row.heading == "Builder One needs access")
        #expect(row.buttons.map(\.label) == ["I have given access", "Cancel task"])
        await model.perform(.grantAccess, on: item.id)
        expectCall(owner, .grantAccess, id: Fixtures.taskID)
        await model.perform(.cancelTask, on: item.id)
        await model.confirmCancel()
        expectCall(owner, .cancelTask, id: Fixtures.taskID)
    }

    @Test("Needs you validates and sends amounts in the Mac’s number format",
          arguments: [NeedsYouItem.taskBudgetReached, .projectBudgetReached])
    func localizedBudget(kind: NeedsYouItem) async {
        let (model, owner, item) = milestoneFive(kind, locale: Locale(identifier: "de_DE"))
        let isCap = kind == .taskBudgetReached
        let operation: ContractOperation = isCap ? .changeTaskCap : .changeBudget
        await model.load()
        await model.perform(isCap ? .raiseCap : .changeBudget, on: item.id)
        for invalid in ["100000000,00", "100000000", "12.50", "12,505"] {
            model.promptText = invalid
            #expect(!model.canConfirmPrompt)
        }
        model.promptText = "12,50"
        #expect(model.canConfirmPrompt)
        await model.confirmPrompt()
        expectCall(owner, operation, id: isCap ? Fixtures.taskID : Self.projectID,
                   body: .object([isCap ? "budget_cap" : "budget": .number(12.5)]))
    }

    @Test("task and project budget items send dollar amounts, and a blank project budget clears the limit")
    func milestoneBudgets() async throws {
        let (taskModel, taskOwner, taskItem) = milestoneFive(.taskBudgetReached)
        await taskModel.load()
        let taskRow = try #require(taskModel.rows.first)
        #expect(taskRow.heading == "Fix the totals on the invoice page reached its spending limit")
        #expect(taskRow.body == "$0.00 reported")
        #expect(taskRow.buttons.map(\.label) == ["Raise the limit", "Cancel task"])
        await taskModel.perform(.raiseCap, on: taskItem.id)
        taskModel.promptText = "25.375"
        await taskModel.confirmPrompt()
        #expect(Fixtures.calls(taskOwner, .changeTaskCap).isEmpty)
        taskModel.promptText = "25.37"
        await taskModel.confirmPrompt()
        expectCall(taskOwner, .changeTaskCap, id: Fixtures.taskID, body: .object(["budget_cap": .number(25.37)]))
        await taskModel.perform(.cancelTask, on: taskItem.id)
        await taskModel.confirmCancel()
        expectCall(taskOwner, .cancelTask, id: Fixtures.taskID)

        let (projectModel, projectOwner, projectItem) = milestoneFive(.projectBudgetReached)
        await projectModel.load()
        let projectRow = try #require(projectModel.rows.first)
        #expect(projectRow.heading == "Invoices reached its budget")
        #expect(projectRow.body == "$0.00 reported")
        #expect(projectRow.buttons.map(\.label) == ["Change the budget", "Continue anyway"])
        await projectModel.perform(.changeBudget, on: projectItem.id)
        projectModel.promptText = ""
        await projectModel.confirmPrompt()
        expectCall(projectOwner, .changeBudget, id: Self.projectID, body: .object(["budget": .null]))
        await projectModel.perform(.resumeProject, on: projectItem.id)
        expectCall(projectOwner, .resumeProject, id: Self.projectID)
    }
}
