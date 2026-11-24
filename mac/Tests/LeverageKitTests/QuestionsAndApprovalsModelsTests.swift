import Foundation
import Testing
@testable import LeverageKit

struct QuestionsAndApprovalsModelsTests {
    @Test("questions and approvals models retain the populated fields from the OpenAPI examples",
          arguments: [
            "Action", "ActionInput", "AnsweredQuestion", "ApprovalJobInput", "ApprovalJobResult",
            "ApprovalMaterial", "AskQuestionCompleted", "AskQuestionResult", "BoardTask", "BriefEntry",
            "Briefing", "ChangeWorkspaceSettingsCompleted", "Decision", "DecisionsList",
            "NextItem", "Project", "ProjectsList", "Question", "QuestionJobInput", "QuestionJobResult",
            "QuestionMaterial", "TaskPage", "WorkspaceSettings",
          ])
    func examples(component: String) throws {
        let check = try #require(Self.roundTrips[component])
        let examples = ContractDocument.examples(of: component)
        try #require(!examples.isEmpty)
        for example in examples {
            let written = try check(example)
            Self.expectPopulatedFields(of: example, in: written, at: component)
        }
    }

    @Test("a claim exposes the typed input for its own kind only",
          arguments: ["question", "approval"])
    func jobClaimInputMatchesKind(kind: String) throws {
        let component = kind == "question" ? "QuestionJobInput" : "ApprovalJobInput"
        let otherComponent = kind == "question" ? "ApprovalJobInput" : "QuestionJobInput"
        var claim = try #require(ContractDocument.examples(of: "ClaimJobResult").first?.objectValue)
        claim["kind"] = .string(kind)
        let input = try #require(ContractDocument.examples(of: component).first)
        claim["input"] = input
        let read = try LeverageJSON.decoder().decode(JobClaim.self, from: ContractDocument.data(.object(claim)))
        if kind == "question" {
            Self.expectPopulatedFields(of: input, in: try Self.encoded(#require(read.input.questionInput)), at: component)
            #expect(read.input.approvalInput == nil)
        } else {
            Self.expectPopulatedFields(of: input, in: try Self.encoded(#require(read.input.approvalInput)), at: component)
            #expect(read.input.questionInput == nil)
        }

        let wrongInput = try #require(ContractDocument.examples(of: otherComponent).first)
        claim["input"] = wrongInput
        let wrong = try LeverageJSON.decoder().decode(JobClaim.self, from: ContractDocument.data(.object(claim)))
        #expect(wrong.input.questionInput == nil && wrong.input.approvalInput == nil)
    }

    @Test("a project says whether it is the workspace's Imaginarium project, and the field is required")
    func projectImaginariumFlag() throws {
        let example = try #require(ContractDocument.examples(of: "Project").first?.objectValue)
        var flagged = example
        flagged["imaginarium"] = .bool(true)
        let read = try LeverageJSON.decoder().decode(Project.self, from: ContractDocument.data(.object(flagged)))
        #expect(read.imaginarium)
        #expect(read.name == example["name"]?.stringValue)

        var plain = example
        plain["imaginarium"] = .bool(false)
        let other = try LeverageJSON.decoder().decode(Project.self, from: ContractDocument.data(.object(plain)))
        #expect(!other.imaginarium)

        var missing = example
        missing["imaginarium"] = nil
        #expect(throws: DecodingError.self) {
            try LeverageJSON.decoder().decode(Project.self, from: ContractDocument.data(.object(missing)))
        }
    }

    @Test("the settings patch omits untouched values and sends null for a cleared recovery ceiling")
    func workspaceSettingsPatch() throws {
        let untouched = try Self.encoded(ChangeWorkspaceSettingsRequest())
        #expect(untouched == ContractDocument.examples(of: "ChangeWorkspaceSettingsRequest").first)

        let clear = try Self.encoded(ChangeWorkspaceSettingsRequest(
            maximumRounds: 4, recoveryTimeCeilingSeconds: .clear))
        #expect(clear == .object(["maximum_rounds": .number(4), "recovery_time_ceiling_seconds": .null]))

        let set = try Self.encoded(ChangeWorkspaceSettingsRequest(recoveryTimeCeilingSeconds: .set(900)))
        #expect(set == .object(["recovery_time_ceiling_seconds": .number(900)]))
    }

    @Test("next reports a question ID for an answer and a task ID for an outward action")
    func nextWork() throws {
        // NextItem's examples cover task and briefing_changed. Use the
        // question and action examples to exercise the two added kinds.
        let questionID = try #require(ContractDocument.examples(of: "Question").first?["id"])
        let taskID = try #require(ContractDocument.examples(of: "Action").first?["task_id"])
        for (kind, id, expected): (String, JSONValue, NextKind) in [
            ("answer", questionID, .answer), ("action", taskID, .action),
        ] {
            let payload = JSONValue.object(["kind": .string(kind), "id": id, "review_id": .null])
            let item = try LeverageJSON.decoder().decode(NextItem.self, from: ContractDocument.data(payload))
            #expect(item.kind == expected && item.id == id.stringValue && item.reviewID == nil)
        }
    }

    @Test("mutations send null when clearing a project, budget, or task cap")
    func clearAmountsAndProject() throws {
        #expect(try Self.encoded(ChangeTaskProjectRequest(projectID: nil)) == .object(["project_id": .null]))
        #expect(try Self.encoded(ChangeBudgetRequest(budget: nil)) == .object(["budget": .null]))
        #expect(try Self.encoded(ChangeTaskCapRequest(budgetCap: nil)) == .object(["budget_cap": .null]))
    }

    @Test("question and approval job requests encode the result and its usage")
    func jobResults() throws {
        let question = JobResultRequest(result: .question(QuestionJobResult(outcome: .passedOn)), tokens: 10, spend: 1)
        let approval = JobResultRequest(
            result: .approval(ApprovalJobResult(decision: .approve, reason: "example")), tokens: 20, spend: 2)
        let approvalExample = try #require(ContractDocument.examples(of: "ApprovalJobResult").first)

        #expect(try Self.encoded(question) == .object([
            "tokens": .number(10), "spend": .number(1),
            "result": .object(["outcome": .string("passed_on"), "answer": .null, "basis": .null]),
        ]))
        #expect(try Self.encoded(approval) == .object([
            "tokens": .number(20), "spend": .number(2), "result": approvalExample,
        ]))
        #expect(ContractDocument.schema("QuestionJobResult")?["properties"]?["answer"]?["maxLength"]?.intValue
                == QuestionJobResult.answerLimit)
        #expect(ContractDocument.schema("ApprovalJobResult")?["properties"]?["reason"]?["maxLength"]?.intValue
                == ApprovalJobResult.reasonLimit)
    }

    private static let roundTrips: [String: @Sendable (JSONValue) throws -> JSONValue] = [
        "Action": roundTrip(OutwardAction.self),
        "ActionInput": roundTrip(ActionInput.self),
        "AnsweredQuestion": roundTrip(AnsweredQuestion.self),
        "ApprovalJobInput": roundTrip(ApprovalJobInput.self),
        "ApprovalJobResult": roundTrip(ApprovalJobResult.self),
        "ApprovalMaterial": roundTrip(ApprovalMaterial.self),
        "AskQuestionCompleted": roundTrip(CommandOutcome<AskQuestionResult>.self),
        "AskQuestionResult": roundTrip(AskQuestionResult.self),
        "BoardTask": roundTrip(BoardTask.self),
        "BriefEntry": roundTrip(BriefEntry.self),
        "Briefing": roundTrip(Briefing.self),
        "ChangeWorkspaceSettingsCompleted": roundTrip(CommandOutcome<WorkspaceSettings>.self),
        "Decision": roundTrip(Decision.self),
        "DecisionsList": roundTrip(DecisionsList.self),
        "NextItem": roundTrip(NextItem.self),
        "Project": roundTrip(Project.self),
        "ProjectsList": roundTrip(ProjectsList.self),
        "Question": roundTrip(Question.self),
        "QuestionJobInput": roundTrip(QuestionJobInput.self),
        "QuestionJobResult": roundTrip(QuestionJobResult.self),
        "QuestionMaterial": roundTrip(QuestionMaterial.self),
        "TaskPage": roundTrip(TaskPage.self),
        "WorkspaceSettings": roundTrip(WorkspaceSettings.self),
    ]

    private static func roundTrip<Model: Codable & SendableMetatype>(_ type: Model.Type)
        -> @Sendable (JSONValue) throws -> JSONValue {
        { example in
            let model = try LeverageJSON.decoder().decode(type, from: ContractDocument.data(example))
            return try encoded(model)
        }
    }

    private static func encoded<T: Encodable>(_ model: T) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: LeverageJSON.encoder().encode(model))
    }

    private static func expectPopulatedFields(of example: JSONValue, in written: JSONValue?, at path: String) {
        switch example {
        case .null:
            return
        case .object(let fields):
            guard let written = written?.objectValue else {
                Issue.record("Missing object at \(path)")
                return
            }
            for (key, value) in fields {
                expectPopulatedFields(of: value, in: written[key], at: "\(path).\(key)")
            }
        case .array(let values):
            guard let written = written?.arrayValue, written.count == values.count else {
                Issue.record("Missing or incomplete array at \(path)")
                return
            }
            for (index, pair) in zip(values, written).enumerated() {
                expectPopulatedFields(of: pair.0, in: pair.1, at: "\(path)[\(index)]")
            }
        case .string(let text):
            if let id = UUID(uuidString: text) {
                #expect(written?.stringValue.flatMap(UUID.init(uuidString:)) == id, "\(path)")
            } else if let date = LeverageJSON.date(from: text) {
                #expect(written?.stringValue.flatMap(LeverageJSON.date(from:)) == date, "\(path)")
            } else {
                #expect(written == example, "\(path)")
            }
        default:
            #expect(written == example, "\(path)")
        }
    }
}
