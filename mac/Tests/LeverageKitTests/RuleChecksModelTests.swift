import Foundation
import Testing
@testable import LeverageKit

// What the Rule checks milestone's models read from the contract's own
// examples (milestone 4 plan sections 2.2 and 2.3), and the generated lists
// that go with them.

@Suite("Rule check models")
struct RuleChecksModelTests {
    private func example<Model: Decodable & SendableMetatype>(
        _ component: String, as type: Model.Type, at index: Int = 0
    ) throws -> Model {
        let examples = ContractDocument.examples(of: component)
        let example = try #require(examples.indices.contains(index) ? examples[index] : nil, "\(component)[\(index)]")
        return try LeverageJSON.decoder().decode(Model.self, from: ContractDocument.data(example))
    }

    /// An example with some of its fields replaced.
    private func decode<Model: Decodable & SendableMetatype>(
        _ component: String, as type: Model.Type, replacing fields: [String: JSONValue]
    ) throws -> Model {
        var object = try #require(ContractDocument.examples(of: component).first?.objectValue)
        for (name, value) in fields { object[name] = value }
        return try LeverageJSON.decoder().decode(Model.self, from: ContractDocument.data(.object(object)))
    }

    // MARK: the rules

    @Test("a rule row reads its version, its sentence, its moment and its counts")
    func ruleRow() throws {
        let list = try example("RulesList", as: RulesList.self)
        let row = try #require(list.rules.first)
        #expect(row.rule.key == "example" && row.rule.currentVersion == 1 && !row.rule.enabled)
        #expect(row.version.ruleID == row.rule.id && row.version.scope.kind == .allTasks)
        #expect(row.version.hook == .taskBeforeReady && row.momentName == RuleHook.taskBeforeReady.momentName)
        #expect(row.sentence == nil && row.acts)
        #expect(row.stats == RuleStats(checks: 4, averageSeconds: 31.5, tokens: 5120, spend: 0, overrides: 1))
        #expect(row.version.createdAt == LeverageJSON.date(from: "2026-01-01T00:00:00Z"))
    }

    @Test("an app-checked rule has a sentence and no instruction, and a rule with no checks has no average")
    func appRule() throws {
        var row = try #require(ContractDocument.examples(of: "RuleWithVersion").first?.objectValue)
        row["sentence"] = .string("Every task has at least one criterion.")
        var stats = try #require(row["stats"]?.objectValue)
        stats["average_seconds"] = .null
        stats["checks"] = .number(0)
        row["stats"] = .object(stats)
        let read = try LeverageJSON.decoder().decode(RuleRow.self, from: ContractDocument.data(.object(row)))
        #expect(read.sentence == "Every task has at least one criterion.")
        #expect(read.stats.averageSeconds == nil && read.stats.checks == 0)
    }

    // MARK: the task page

    @Test("a task page reads its steps, its checks with their attempts, its pending command and its draft")
    func taskPage() throws {
        let page = try example("TaskPage", as: TaskPage.self)
        let step = try #require(page.steps.first)
        #expect(page.steps.count == 1)
        #expect(step.kind == .check && step.stepClass == .ruleCheck && step.round == 0)
        #expect(step.seconds == 40 && step.closedAt == LeverageJSON.date(from: "2026-01-01T00:00:40Z"))
        #expect(step.subjectKind == .pendingTransition && step.causeKind == .rule && step.seatID == nil)
        #expect(page.lifetimeSeconds == 40 && page.asOf == LeverageJSON.date(from: "2026-01-01T00:00:40Z"))
        let check = try #require(page.ruleChecks.first)
        #expect(check.ruleName == "Every task needs specific details" && check.version == 1)
        #expect(check.hook == .taskBeforeReady && check.checker == .model && check.onFail == .block)
        #expect(check.result == .passed && check.effect == nil && check.reason == "Made-up reason.")
        #expect(check.attempts == [CheckAttempt(
            attemptNumber: 1, queuedAt: LeverageJSON.date(from: "2026-01-01T00:00:00Z")!,
            startedAt: LeverageJSON.date(from: "2026-01-01T00:00:10Z"),
            finishedAt: LeverageJSON.date(from: "2026-01-01T00:00:40Z"))])
        #expect(check.queueSeconds == 10 && check.runSeconds == 30)
        #expect(!check.canOverride && !check.canRerun && check.overriddenAt == nil)
        #expect(page.pending == nil && page.draft == .none)
    }

    @Test("a task page reads a waiting command and a draft that is being written")
    func taskPagePendingAndDraft() throws {
        let pending = try example("PendingCommand", as: PendingState.self)
        #expect(pending.command == .completeContract && pending.waitingOnRuleIDs.count == 1)
        let encoded = try JSONDecoder().decode(JSONValue.self, from: ContractDocument.data(
            try #require(ContractDocument.examples(of: "PendingCommand").first)))
        let page = try decode("TaskPage", as: TaskPage.self, replacing: ["pending": encoded, "draft": .string("writing")])
        #expect(page.pending == pending && page.draft == .writing)
    }

    @Test("an overridden check reads who let it through and why")
    func overriddenCheck() throws {
        let check = try decode("TaskRuleCheck", as: RuleCheckRow.self, replacing: [
            "result": .string("failed"), "effect": .string("refused"), "overridden_at": .string("2026-01-01T00:01:00Z"),
            "overridden_by_user_id": .string("00000000-0000-4000-8000-0000000000c1"),
            "override_reason": .string("Made-up reason."), "round": .null, "can_rerun": .bool(true),
        ])
        #expect(check.result == .failed && check.effect == .refused && check.round == nil)
        #expect(check.overriddenAt == LeverageJSON.date(from: "2026-01-01T00:01:00Z"))
        #expect(check.overriddenByUserID == UUID(uuidString: "00000000-0000-4000-8000-0000000000c1"))
        #expect(check.overrideReason == "Made-up reason." && check.canRerun)
    }

    @Test("a board card reads whether it is being checked and why a check stopped it")
    func boardTask() throws {
        let board = try example("Board", as: Board.self)
        #expect(board.tasks.allSatisfy { !$0.checking && $0.checkReason == nil })
        let card = try #require(ContractDocument.examples(of: "BoardTask").first?.objectValue)
        var changed = card
        changed["checking"] = .bool(true)
        changed["check_reason"] = .string("Made-up reason.")
        let read = try LeverageJSON.decoder().decode(BoardTask.self, from: ContractDocument.data(.object(changed)))
        #expect(read.checking && read.checkReason == "Made-up reason.")
    }

    @Test("the system health reads how many checks are waiting")
    func health() throws {
        #expect(try example("SystemHealth", as: SystemHealth.self).waitingChecks == 0)
        let read = try decode("SystemHealth", as: SystemHealth.self, replacing: [
            "waiting_checks": .number(3), "orchestrator": .string("offline"),
        ])
        #expect(read.waitingChecks == 3 && read.orchestrator == .offline)
    }

    @Test("an open orchestrator_offline item reads the number of checks now waiting")
    func inboxWaitingChecks() throws {
        func item(_ facts: [String: JSONValue]) -> InboxItem {
            InboxItem(
                id: UUID(), kind: .orchestratorOffline, aboutKind: .task, aboutID: UUID(), choices: [], facts: facts,
                openedAt: Date(), openedSeq: 1)
        }
        #expect(item(["waiting_checks": .number(3)]).waitingChecks == 3)
        #expect(item(["waiting_checks": .number(0)]).waitingChecks == 0)
        #expect(item([:]).waitingChecks == nil)
        #expect(item(["waiting_checks": .string("3")]).waitingChecks == nil)
        #expect(item(["waiting_checks": .number(2.5)]).waitingChecks == nil)
        #expect(item(["waiting_checks": .number(-1)]).waitingChecks == nil)
    }

    // MARK: jobs

    @Test("a rule-check claim reads the rule, the contract, the quoted text and when its result is due")
    func ruleCheckClaim() throws {
        let claim = try example("ClaimJobResult", as: JobClaim.self)
        #expect(claim.kind == .ruleCheck && claim.credentialID == nil && claim.model == nil)
        #expect(claim.runDueAt == LeverageJSON.date(from: "2026-01-01T00:05:00Z"))
        guard case .ruleCheck(let input) = claim.input else {
            Issue.record("a rule_check job has a rule check's input: \(claim.input)")
            return
        }
        #expect(input.attemptNumber == 1 && input.hook == .taskBeforeReady && input.projectID != nil)
        let material = input.material
        #expect(material.instruction == "Every task names the page it changes.")
        #expect(material.moment == RuleHook.taskBeforeReady.momentName && !material.mayAnswerNotApplicable)
        #expect(material.contract.title == "Made-up task" && material.contract.details == nil)
        #expect(material.contract.criteria.map(\.kind) == [.build, .review])
        #expect(material.contract.criteria.map(\.state) == [.open, .open])
        #expect(material.quoted == [QuotedText(label: .handoffNote, text: "Made-up note.")])
        #expect(material.roleFile.hasPrefix("You are the orchestrator."))
    }

    @Test("a contract-draft claim reads the task's text, its criteria and the three stored values")
    func contractDraftClaim() throws {
        let input = try #require(ContractDocument.examples(of: "ContractDraftJobInput").first)
        var claim = try #require(ContractDocument.examples(of: "ClaimJobResult").first?.objectValue)
        claim["kind"] = .string("contract_draft")
        claim["input"] = input
        claim["model"] = .string("made-up-model")
        let read = try LeverageJSON.decoder().decode(JobClaim.self, from: ContractDocument.data(.object(claim)))
        guard case .contractDraft(let draft) = read.input else {
            Issue.record("a contract_draft job has a draft's input: \(read.input)")
            return
        }
        #expect(read.model == "made-up-model")
        #expect(draft.briefVersion == 1 && draft.material.title == "Made-up task")
        #expect(draft.material.criteria == [CriterionInput(text: "A reviewer has checked the work.", kind: .review)])
        #expect(draft.material.workReference == nil && draft.material.minimumStrengthRank == nil)
        #expect(draft.material.budgetCap == nil && draft.material.brief.isEmpty)
    }

    @Test("a draft keeps the stored values it was given")
    func draftStoredValues() throws {
        var material = try #require(ContractDocument.examples(of: "DraftMaterial").first?.objectValue)
        material["work_reference"] = .string("/made/up")
        material["minimum_strength_rank"] = .number(2)
        material["budget_cap"] = .number(12.5)
        let read = try LeverageJSON.decoder().decode(DraftMaterial.self, from: ContractDocument.data(.object(material)))
        #expect(read.workReference == "/made/up" && read.minimumStrengthRank == 2 && read.budgetCap == 12.5)
    }

    @Test("a question or an approval is kept as the JSON it came as, and a claim whose input does not fit its kind is refused")
    func otherJobs() throws {
        var claim = try #require(ContractDocument.examples(of: "ClaimJobResult").first?.objectValue)
        claim["kind"] = .string("question")
        claim["input"] = .object(["question_id": .string("00000000-0000-4000-8000-0000000000c2")])
        let read = try LeverageJSON.decoder().decode(JobClaim.self, from: ContractDocument.data(.object(claim)))
        #expect(read.input == .other(.question, .object(["question_id": .string("00000000-0000-4000-8000-0000000000c2")])))

        claim["kind"] = .string("rule_check")
        #expect(throws: DecodingError.self) {
            _ = try LeverageJSON.decoder().decode(JobClaim.self, from: ContractDocument.data(.object(claim)))
        }
        claim["kind"] = .string("a_new_kind")
        #expect(throws: DecodingError.self) {
            _ = try LeverageJSON.decoder().decode(JobClaim.self, from: ContractDocument.data(.object(claim)))
        }
    }

    @Test("the longest reason is the interface schema's")
    func reasonLimit() {
        let limit = ContractDocument.schema("RuleCheckJobResult")?["properties"]?["reason"]?["maxLength"]
        #expect(limit == .number(Double(RuleCheckVerdict.reasonLimit)))
    }

    // MARK: what the generator wrote

    @Test("each hook's moment name is the one hooks.json and the interface schema give, in the same order")
    func momentNames() throws {
        let data = try Data(contentsOf: ContractDocument.folder.appendingPathComponent("hooks.json"))
        let hooks = try #require(JSONDecoder().decode(JSONValue.self, from: data)["hooks"]?.arrayValue)
        #expect(hooks.compactMap { $0["hook"]?.stringValue } == RuleHook.allCases.map(\.rawValue))
        #expect(hooks.compactMap { $0["moment_name"]?.stringValue } == RuleHook.allCases.map(\.momentName))
        for (component, path) in [("RuleWithVersion", "moment_name"), ("TaskRuleCheck", "moment_name"),
                                  ("CheckMaterial", "moment")] {
            let allowed = ContractDocument.schema(component)?["properties"]?[path]?["enum"]?.arrayValue ?? []
            #expect(allowed.compactMap(\.stringValue) == RuleHook.allCases.map(\.momentName), "\(component).\(path)")
        }
    }

    @Test("an owner's own rule may use the five hooks the registry names, and the Add rule enum is those five")
    func customHooks() {
        let custom = ContractDocument.registry["custom_rule_hooks"]?.arrayValue?.compactMap(\.stringValue) ?? []
        #expect(RuleHook.allCases.filter(\.isCustomAllowed).map(\.rawValue) == custom)
        #expect(custom.count == 5)
    }

    @Test("the tested providers are the registry's, as providers, and none is listed yet")
    func testedProviders() {
        let listed = ContractDocument.registry["lists"]?["orchestrator_tested_providers"]?.arrayValue?
            .compactMap(\.stringValue) ?? ["not read"]
        #expect(ContractLists.orchestratorTestedProviders.map(\.rawValue) == listed)
        #expect(ContractLists.orchestratorTestedProviders.allSatisfy { $0.kind == .login })
    }

    @Test("Write the shipped rules is a command the Mac side knows, and no operation")
    func installShippedRules() {
        #expect(CommandName(rawValue: "install_shipped_rules") != nil)
        #expect(ContractDocument.registry["operations"]?.arrayValue?.contains {
            $0["commands"]?.arrayValue?.contains(.string("install_shipped_rules")) == true
        } == false)
    }
}
