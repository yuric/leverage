import Foundation
import LeverageKit
import LeverageTestSupport
import SwiftUI
import Testing

@testable import LeverageApp

/// The Rules screen's rows, switches and counts (RD-8, RD-25 to RD-29, RM-1,
/// RM-2, WP16).
@MainActor
@Suite("RulesModel")
struct RulesModelTests {
    private typealias Fixtures = RulesFixtures

    private func makeModel(_ owner: FakeOwnerAPI) -> RulesModel {
        RulesModel(api: owner, calendar: Fixtures.utc, locale: Fixtures.usEnglish)
    }

    private func owner(_ rows: [RuleRow]) -> FakeOwnerAPI {
        let owner = FakeOwnerAPI()
        owner.script { $0.listRules = { RulesList(rules: rows) } }
        return owner
    }

    private func lines(_ rows: [RuleRow]) -> [RuleLine] {
        RulesModel.lines(for: rows, calendar: Fixtures.utc, locale: Fixtures.usEnglish)
    }

    /// The one line of one row; the test stops here if there is not exactly one.
    private func line(_ row: RuleRow) throws -> RuleLine {
        let result = lines([row])
        try #require(result.count == 1)
        return result[0]
    }

    private func row(
        enabled: Bool = true, scope: RuleScope = .allTasks, origin: RuleOrigin = .custom, onFail: RuleOnFail? = .block,
        stats: RuleStats = RulesFixtures.stats(), checker: RuleChecker = .model
    ) -> RuleRow {
        Fixtures.row(
            checker: checker, scope: scope, onFail: onFail, origin: origin, enabled: enabled, stats: stats)
    }

    // MARK: loading

    @Test("a new Rules screen is loading and shows no rows")
    func startsLoading() {
        let model = makeModel(FakeOwnerAPI())
        #expect(model.state == .loading)
        #expect(model.lines.isEmpty)
    }

    @Test("loading reads the rules once and keeps the server's order")
    func loadsInOrder() async throws {
        let rows = try Fixtures.shippedRows()
        let owner = owner(rows)
        let model = makeModel(owner)
        await model.load()
        #expect(model.state == .loaded)
        #expect(model.lines.map(\.id) == rows.map(\.rule.id))
        #expect(owner.calls.map(\.operation) == [.listRules])
    }

    @Test("a call that does not get through shows a sentence, and a 401 shows the signed-out state")
    func failures() async {
        let failing = FakeOwnerAPI()
        failing.script { $0.listRules = { throw URLError(.timedOut) } }
        let model = makeModel(failing)
        await model.load()
        #expect(model.state == .failed(.cannotReach))
        #expect(model.lines.isEmpty)

        let signedOut = FakeOwnerAPI()
        signedOut.script { $0.listRules = { throw ShellFixtures.unauthenticated() } }
        let ended = makeModel(signedOut)
        await ended.load()
        #expect(ended.state == .signedOut)
    }

    /// The approvals rule as the server sent it after sign-up (track F2's own
    /// compose project): a model rule whose instruction is not written yet,
    /// so `null` where shipped_rules.json holds a placeholder object.
    private static let approvalsAsSent = #"""
        {"rules": [{"rule": {"id": "88c952ef-3868-4c73-8f36-911d36f37186", "key": "orchestrator_approves_actions",
        "enabled": true, "current_version": 1}, "version": {"id": "aa094407-5c4e-451a-b539-7a60ee4cf308",
        "rule_id": "88c952ef-3868-4c73-8f36-911d36f37186", "version": 1, "key": "orchestrator_approves_actions",
        "name": "The orchestrator approves outward actions itself", "hook": "action.requested",
        "scope": {"kind": "all_tasks", "project_ids": null, "action_kinds": null}, "kind": "policy", "checker": "model",
        "on_fail": null, "route": null, "queue_timeout_seconds": null, "run_timeout_seconds": null, "instruction": null,
        "parameters": {}, "origin": "shipped", "author_kind": "owner", "author_id": "3ebd52d1-ba10-4c7a-ba63-3afc34c7cd75",
        "created_at": "2026-11-20T17:36:19.508042Z"}, "sentence": null, "moment_name": "before anything goes out",
        "acts": false, "stats": {"checks": 0, "average_seconds": null, "tokens": 0, "spend": 0.0, "overrides": 0}}]}
        """#

    @Test("the approvals rule as the server sends it, with no instruction yet, loads as a row with no text")
    func approvalsRuleWithNoInstruction() async throws {
        let host = "rules-approvals-as-sent.test"
        let session = StubURLProtocol.session(host: host, answer: .init(status: 200, json: Self.approvalsAsSent))
        let client = OwnerClient(baseURL: URL(string: "http://\(host)")!, sessionToken: "lvo_x", session: session)
        let model = RulesModel(api: client, calendar: Fixtures.utc, locale: Fixtures.usEnglish)

        await model.load()

        #expect(model.state == .loaded)
        let line = try #require(model.lines.count == 1 ? model.lines.first : nil)
        #expect(line.name == "The orchestrator approves outward actions itself")
        #expect(line.whenItRuns == "Before anything goes out")
        #expect(line.checkedBy == RulesCopy.checkerModel.text)
        #expect(line.detail.isEmpty)
        #expect(line.detailIsInstruction)
        #expect(line.notActing == RulesCopy.notActing.text)
    }

    // MARK: the seven rows and their words (RM-1)

    @Test("the seven shipped rules read as the owner's words, one by one")
    func sevenRows() throws {
        let rows = try Fixtures.shippedRows()
        #expect(rows.count == 7)
        let result = lines(rows)
        #expect(result.map(\.name) == [
            "Every task needs acceptance criteria",
            "Every task needs specific details",
            "Workers ask the orchestrator before they ask you",
            "A different provider reviews every task",
            "Repeated failed reviews move a task to a stronger model",
            "Projects pause when they reach their budget",
            "The orchestrator approves outward actions itself",
        ])
        #expect(result.map(\.whenItRuns) == [
            "When a task is ready to start", "When a task is ready to start", "When a worker asks a question",
            "When a reviewer claims a review", "When a review fails", "When spending is reported",
            "Before anything goes out",
        ])
        #expect(result.map(\.appliesTo) == Array(repeating: "Every task", count: 7))
        #expect(result.map(\.checkedBy) == [
            "leverage checks this itself", "An agent checks this", "leverage checks this itself",
            "leverage checks this itself", "leverage checks this itself", "leverage checks this itself",
            "An agent checks this",
        ])
        #expect(result.map(\.ifItFails) == ["Stop the task", "Stop the task", nil, nil, nil, nil, nil])
        #expect(result.map(\.isShipped) == Array(repeating: true, count: 7))
        #expect(result.allSatisfy { $0.isOn })
    }

    @Test("an app rule shows the sentence made from its parameters, a model rule its instruction")
    func sentenceOrInstruction() throws {
        let rows = try Fixtures.shippedRows()
        let result = lines(rows)
        try #require(result.count == 7)
        #expect(result[0].detail == Fixtures.sentences["acceptance_criteria"])
        #expect(!result[0].detailIsInstruction)
        let instruction = try #require(rows[1].version.instruction)
        #expect(!instruction.isEmpty)
        #expect(result[1].detail == instruction)
        #expect(result[1].detailIsInstruction)
        #expect(result[3].detail == Fixtures.sentences["different_provider_review"])
    }

    @Test("the four rules whose effect is a later version's say so, and the three that act do not")
    func notActingYet() throws {
        let result = lines(try Fixtures.shippedRows())
        let later = "Starts working in a later version of leverage"
        #expect(result.map(\.notActing) == [nil, nil, later, nil, later, later, later])
    }

    @Test("a rule that is off shows its switch off, and a scope reads in words")
    func switchAndScope() throws {
        let result = try line(row(enabled: false, scope: .checkerDecides))
        #expect(!result.isOn)
        #expect(result.appliesTo == "The agent that checks decides")
        let projects = try line(row(scope: RuleScope(kind: .namedProjects, projectIDs: [])))
        #expect(projects.appliesTo == "Named projects")
        let actions = try line(row(scope: RuleScope(kind: .actionKinds, actionKinds: [.pay])))
        #expect(actions.appliesTo == "Tasks that end in some outward actions")
    }

    @Test("a custom rule is not shipped, and its wording shows the date it was saved")
    func customAndWording() throws {
        let result = try line(row(origin: .custom))
        #expect(!result.isShipped)
        #expect(result.wording == "Wording of Nov 11, 2026")
        #expect((try line(row(onFail: .warn))).ifItFails == "Only note it")
    }

    // MARK: the counts line (RD-26, RD-32)

    @Test("a rule that has not run says so, without a time or a cost")
    func countsNone() throws {
        #expect((try line(row())).counts == "Has not run yet")
    }

    @Test("a model rule shows how often it ran, its average time, tokens, reported spend and what was let through")
    func countsModel() throws {
        let stats = Fixtures.stats(checks: 12, average: 8.4, tokens: 4210, spend: Decimal(string: "0.31")!, overrides: 1)
        #expect((try line(row(stats: stats))).counts
            == "Ran 12 times · average 8 seconds · 4,210 tokens · $0.31 reported · let through once")
    }

    @Test("a model rule that ran once and cost nothing still shows its tokens and spend as 0")
    func countsModelFree() throws {
        let stats = Fixtures.stats(checks: 1, average: 61, tokens: 0, spend: 0, overrides: 0)
        #expect((try line(row(stats: stats))).counts == "Ran once · average 1 minute · 0 tokens · $0.00 reported")
    }

    @Test("an app rule shows no tokens or spend, and a time under a second reads that way")
    func countsApp() throws {
        let stats = Fixtures.stats(checks: 3, average: 0.02, tokens: 0, spend: 0, overrides: 2)
        #expect((try line(row(stats: stats, checker: .app))).counts
            == "Ran 3 times · average under a second · let through 2 times")
    }

    @Test("an app rule that spent something shows it, and no finished attempt leaves the average out")
    func countsAppSpent() throws {
        let stats = Fixtures.stats(checks: 2, average: nil, tokens: 90, spend: 0, overrides: 0)
        #expect((try line(row(stats: stats, checker: .app))).counts == "Ran 2 times · 90 tokens")
    }

    // MARK: the switch

    @Test("a switch sends turn on, then reads the rules again")
    func turnOn() async {
        let owner = owner([Fixtures.row(number: 7, enabled: false)])
        owner.script { $0.enableRule = { _, key in .completed(.object([:]), key: key.value, command: .enableRule) } }
        let model = makeModel(owner)
        await model.load()
        owner.forgetCalls()
        await model.setEnabled(Fixtures.id(7), to: true)
        #expect(owner.calls.map(\.operation) == [.enableRule, .listRules])
        #expect(owner.calls.first?.path == ["id": Fixtures.id(7).contractString])
        #expect(owner.calls.first?.key != nil)
        #expect(model.failure == nil)
        #expect(model.changing.isEmpty)
    }

    @Test("a switch sends turn off, and what the server then says is what is shown")
    func turnOff() async {
        let on = Locked(true)
        let owner = FakeOwnerAPI()
        owner.script {
            $0.listRules = { RulesList(rules: [Fixtures.row(number: 7, enabled: on.value)]) }
            $0.disableRule = { _, key in
                on.value = false
                return .completed(.object([:]), key: key.value, command: .disableRule)
            }
        }
        let model = makeModel(owner)
        await model.load()
        #expect(model.lines.first?.isOn == true)
        await model.setEnabled(Fixtures.id(7), to: false)
        #expect(owner.calls.map(\.operation) == [.listRules, .disableRule, .listRules])
        #expect(model.lines.first?.isOn == false)
    }

    @Test("a switch the server refuses shows a sentence and reads again, so the screen shows what is true")
    func switchRefused() async {
        let owner = owner([Fixtures.row(number: 7)])
        owner.script {
            $0.disableRule = { _, key in
                .refused(Refusal(code: .invalidState, ruleID: nil, reason: nil), key: key.value, command: .disableRule)
            }
        }
        let model = makeModel(owner)
        await model.load()
        await model.setEnabled(Fixtures.id(7), to: false)
        #expect(model.failure == .refusalInvalidState)
        #expect(owner.calls.map(\.operation) == [.listRules, .disableRule, .listRules])
        #expect(model.lines.first?.isOn == true)
        #expect(model.changing.isEmpty)
    }

    @Test("the next switch clears the sentence of the one that failed")
    func failureClears() async {
        let owner = owner([Fixtures.row(number: 7)])
        let works = Locked(false)
        owner.script {
            $0.disableRule = { _, key in
                if works.value { return .completed(.object([:]), key: key.value, command: .disableRule) }
                throw URLError(.timedOut)
            }
        }
        let model = makeModel(owner)
        await model.load()
        await model.setEnabled(Fixtures.id(7), to: false)
        #expect(model.failure == .cannotReach)
        works.value = true
        await model.setEnabled(Fixtures.id(7), to: false)
        #expect(model.failure == nil)
    }

    // MARK: reading again (RM-2)

    private func eventPage(_ type: EventType, seq: Int) -> EventsPage {
        EventsPage(
            events: [EventRecord(id: UUID(), workspaceID: UUID(), seq: seq, at: Date(), type: type, actorKind: .owner)],
            nextAfterSeq: seq)
    }

    private func tailedOwner(reads: Locked<Int>, batches: Locked<[EventsPage]>) -> FakeOwnerAPI {
        let owner = FakeOwnerAPI()
        owner.script {
            $0.listRules = {
                reads.update { $0 += 1 }
                return RulesList(rules: [])
            }
            $0.events = { _, _, _ in
                while true {
                    if let page = batches.update({ $0.isEmpty ? nil : $0.removeFirst() }) { return page }
                    try await Task.sleep(for: .milliseconds(2))
                }
            }
        }
        return owner
    }

    @Test("an event of a rule type reads the rules again, and an event of another type does not")
    func readsAgainOnRuleEvents() async {
        let reads = Locked(0)
        let batches = Locked<[EventsPage]>([])
        let owner = tailedOwner(reads: reads, batches: batches)
        let feed = EventFeed(owner: owner, waitSeconds: 25, retryDelay: .milliseconds(5))
        let model = makeModel(owner)
        model.attach(to: feed)
        await model.load()
        feed.noteRead(asOfSeq: 0)
        #expect(reads.value == 1)

        batches.update { $0.append(eventPage(.taskCreated, seq: 1)) }
        #expect(await ShellFixtures.eventually { feed.revision >= 1 })
        try? await Task.sleep(for: .milliseconds(30))
        #expect(reads.value == 1, "a task event is not a rule event")

        let types: [EventType] = [.ruleChanged, .ruleEnabled, .ruleDisabled, .ruleReverted, .ruleRemoved, .ruleCreated]
        for (index, type) in types.enumerated() {
            batches.update { $0.append(eventPage(type, seq: 10 + index)) }
            #expect(await ShellFixtures.eventually { reads.value == 2 + index }, "\(type)")
        }
        model.detach()
        feed.stop()
    }

    @Test("after detach a rule event reads nothing")
    func detachStops() async {
        let reads = Locked(0)
        let batches = Locked<[EventsPage]>([])
        let owner = tailedOwner(reads: reads, batches: batches)
        let feed = EventFeed(owner: owner, waitSeconds: 25, retryDelay: .milliseconds(5))
        let model = makeModel(owner)
        model.attach(to: feed)
        model.detach()
        feed.noteRead(asOfSeq: 0)
        batches.update { $0.append(eventPage(.ruleChanged, seq: 1)) }
        #expect(await ShellFixtures.eventually { feed.revision >= 1 })
        try? await Task.sleep(for: .milliseconds(30))
        #expect(reads.value == 0)
        feed.stop()
    }
}
