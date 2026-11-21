import Foundation
import Testing
@testable import LeverageKit

struct QuestionsAndApprovalsModelsTests {
    @Test("questions and approvals models retain the populated fields from the OpenAPI examples",
          arguments: [
            "Action", "ActionInput", "AnsweredQuestion", "ApprovalJobInput", "ApprovalJobResult",
            "ApprovalMaterial", "AskQuestionCompleted", "AskQuestionResult", "BoardTask", "BriefEntry",
            "Briefing", "ChangeWorkspaceSettingsCompleted", "Decision", "DecisionsList", "LandingPrompt",
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

        claim["input"] = try #require(ContractDocument.examples(of: otherComponent).first)
        let wrong = try LeverageJSON.decoder().decode(JobClaim.self, from: ContractDocument.data(.object(claim)))
        #expect(wrong.input.questionInput == nil && wrong.input.approvalInput == nil)
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

    private static let roundTrips: [String: @Sendable (JSONValue) throws -> JSONValue] = [
        "Action": roundTrip(OutwardAction.self),
        "ActionInput": roundTripActionInput,
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
        "LandingPrompt": roundTrip(LandingPrompt.self),
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

    private static func roundTripActionInput(_ example: JSONValue) throws -> JSONValue {
        let kind = try #require(example["kind"]?.stringValue.flatMap(ActionKind.init(rawValue:)))
        let description = try #require(example["description"]?.stringValue)
        return try encoded(ActionInput(kind: kind, description: description))
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
