import Foundation
import Testing
@testable import LeverageKit

// Every response the Mac side reads is decoded from the contract's own
// examples. SwiftPM takes no resources from outside mac/, so the tests find
// api/contract/ from this file's own path.

/// The contract's interface schema and registry, read as JSON values.
enum ContractDocument {
    static let folder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // LeverageKitTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // mac
        .deletingLastPathComponent()  // repository root
        .appendingPathComponent("api/contract")

    static let openAPI: JSONValue = load("openapi.json")
    static let registry: JSONValue = load("registry.json")

    private static func load(_ name: String) -> JSONValue {
        do {
            let data = try Data(contentsOf: folder.appendingPathComponent(name))
            return try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            fatalError("cannot read api/contract/\(name): \(error)")
        }
    }

    static let served = coreLoop + handoff + ruleChecks + questionsAndApprovals + credentials

    // Milestone 2 (Core loop).
    static let coreLoop: [String] = [
        "get_join", "get_next", "get_command", "claim_next_task", "get_task_briefing",
        "acknowledge_task_briefing", "heartbeat_task", "start_criterion", "pass_criterion",
        "submit_task", "release_task", "claim_next_review", "heartbeat_review",
        "release_review", "get_review_briefing", "acknowledge_review_briefing", "give_verdict",
        "get_health",
        "sign_in_owner", "get_owner_command", "list_events", "get_board", "get_task",
        "list_seats", "list_credentials", "get_system_health", "add_task", "complete_contract",
        "cancel_task", "allow_another_round", "connect_seat", "start_seat", "stop_seat",
        "remove_seat", "issue_helper_token", "add_credential", "verify_credential", "install_tool",
        "get_helper_next", "report_request_result", "issue_seat_token", "report_run_started",
        "report_run_stopped",
        "get_setup_state", "create_owner", "sign_out_owner", "get_helper_request",
        "report_request_progress", "issue_landing_prompt",
    ]

    // Milestone 3 (Handoff).
    static let handoff: [String] = [
        "report_limit", "report_signed_out", "sign_in_again", "list_inbox", "promote_task",
        "edit_contract", "hold_task", "resume_task", "pause_seat", "resume_seat", "change_seat",
    ]

    // Milestone 4 (Rule checks).
    static let ruleChecks: [String] = [
        "claim_next_job", "submit_job_result", "list_rules", "add_rule", "save_rule", "enable_rule",
        "disable_rule", "revert_rule", "remove_rule", "rerun_check", "override_check", "draft_contract",
    ]

    // Milestone 5 (Questions and approvals).
    static let questionsAndApprovals: [String] = [
        "ask_question", "get_question", "request_access", "report_cost",
        "start_action", "report_action_done", "list_decisions", "list_projects",
        "create_project", "edit_brief", "pause_project", "resume_project",
        "change_budget", "delete_project_content", "change_task_priority", "change_task_project",
        "change_task_cap", "return_for_rework", "offer_task_again", "grant_access",
        "delete_task_content", "answer_question", "overturn_answer", "approve_action",
        "stop_action", "waive_action", "mark_action_done", "overturn_approval",
        "get_workspace_settings", "change_workspace_settings",
    ]

    // Milestone 6 (Credentials).
    static let credentials: [String] = [
        "rename_credential", "remove_credential", "refresh_usage", "verify_all_credentials",
        "reorder_credentials", "report_reading",
    ]

    /// The registry entry of one operation.
    static func operation(_ id: String) -> JSONValue? {
        registry["operations"]?.arrayValue?.first { $0["operation_id"]?.stringValue == id }
    }

    /// The interface schema's description of one operation.
    static func openAPIOperation(_ id: String) -> JSONValue? {
        guard let entry = operation(id),
              let path = entry["path"]?.stringValue,
              let method = entry["method"]?.stringValue?.lowercased()
        else { return nil }
        return openAPI["paths"]?[path]?[method]
    }

    static func schema(_ name: String) -> JSONValue? {
        openAPI["components"]?["schemas"]?[name]
    }

    /// The component name a `$ref` points at, through `components/responses`.
    static func component(of ref: String) -> String? {
        let name = String(ref.split(separator: "/").last ?? "")
        if ref.hasPrefix("#/components/responses/") {
            guard let inner = openAPI["components"]?["responses"]?[name]?["content"]?[
                "application/json"]?["schema"]?["$ref"]?.stringValue
            else { return nil }
            return component(of: inner)
        }
        return name
    }

    /// Each response status of an operation and the component it answers.
    static func responses(of id: String) -> [(status: String, component: String)] {
        guard let responses = openAPIOperation(id)?["responses"]?.objectValue else { return [] }
        return responses.keys.sorted().compactMap { status in
            let response = responses[status]!
            let ref = response["$ref"]?.stringValue
                ?? response["content"]?["application/json"]?["schema"]?["$ref"]?.stringValue
            guard let ref, let name = component(of: ref) else { return nil }
            return (status, name)
        }
    }

    static func examples(of component: String) -> [JSONValue] {
        schema(component)?["examples"]?.arrayValue ?? []
    }

    static func data(_ value: JSONValue) throws -> Data {
        try JSONEncoder().encode(value)
    }
}

private func decodes<Model: Decodable & SendableMetatype>(_ type: Model.Type) -> @Sendable (Data) throws -> Void {
    { data in _ = try LeverageJSON.decoder().decode(Model.self, from: data) }
}

@Suite("Contract examples")
struct ContractExamplesTests {
    /// The Swift model of every component a served operation answers.
    static let models: [String: @Sendable (Data) throws -> Void] = [
        "NextItem": decodes(NextItem.self),
        "CommandOutcome": decodes(PlainOutcome.self),
        "CompletedOutcome": decodes(PlainOutcome.self),
        "PendingOutcome": decodes(PlainOutcome.self),
        "RefusedOutcome": decodes(PlainOutcome.self),
        "ClaimNextTaskCompleted": decodes(CommandOutcome<TaskClaim>.self),
        "ClaimNextReviewCompleted": decodes(CommandOutcome<ReviewClaim>.self),
        "HeartbeatTaskCompleted": decodes(CommandOutcome<HeartbeatResult>.self),
        "HeartbeatReviewCompleted": decodes(CommandOutcome<HeartbeatResult>.self),
        "AddTaskCompleted": decodes(CommandOutcome<TaskCreatedResult>.self),
        "AddCredentialCompleted": decodes(CommandOutcome<AddCredentialResult>.self),
        "OwnerSessionCompleted": decodes(CommandOutcome<OwnerSessionAnswer>.self),
        "HelperTokenIssuedCompleted": decodes(CommandOutcome<HelperTokenAnswer>.self),
        "SeatConnectedCompleted": decodes(CommandOutcome<SeatConnected>.self),
        "SeatTokenPickupCompleted": decodes(CommandOutcome<SeatTokenPickupAnswer>.self),
        "BriefingResponse": decodes(BriefingResponse.self),
        "Health": decodes(Health.self),
        "EventsPage": decodes(EventsPage.self),
        "Board": decodes(Board.self),
        "TaskPage": decodes(TaskPage.self),
        "SeatsList": decodes(SeatsList.self),
        "CredentialsList": decodes(CredentialsList.self),
        "SystemHealth": decodes(SystemHealth.self),
        "ClaimNextJobCompleted": decodes(CommandOutcome<JobClaim>.self),
        "DraftContractCompleted": decodes(CommandOutcome<DraftContractResult>.self),
        "RulesList": decodes(RulesList.self),
        "InboxPage": decodes(InboxPage.self),
        "HelperNext": decodes(HelperNext.self),
        "HelperRequestStatus": decodes(HelperRequestStatus.self),
        "SetupState": decodes(SetupState.self),
        "LandingPromptIssuedCompleted": decodes(CommandOutcome<LandingPromptIssuedAnswer>.self),
        "JoinInstructions": decodes(JoinInstructions.self),
        "TransportError": decodes(TransportError.self),
        "Refusal": decodes(Refusal.self),
        "AskQuestionCompleted": decodes(CommandOutcome<AskQuestionResult>.self),
        "Question": decodes(Question.self),
        "DecisionsList": decodes(DecisionsList.self),
        "ProjectsList": decodes(ProjectsList.self),
        "WorkspaceSettings": decodes(WorkspaceSettings.self),
        "ChangeWorkspaceSettingsCompleted": decodes(CommandOutcome<WorkspaceSettings>.self),
    ]

    @Test("every served operation is in the registry and the interface schema")
    func servedOperationsExist() {
        #expect(ContractDocument.served.count == 108)
        #expect(ContractDocument.handoff.first == "report_limit")
        #expect(ContractDocument.handoff.last == "change_seat")
        #expect(ContractDocument.ruleChecks.first == "claim_next_job")
        for id in ContractDocument.served {
            #expect(ContractDocument.operation(id) != nil, "\(id) is not in registry.json")
            #expect(ContractDocument.openAPIOperation(id) != nil, "\(id) is not in openapi.json")
        }
    }

    @Test("every response example of every served operation decodes into its model")
    func everyResponseExampleDecodes() throws {
        var decoded = 0
        for id in ContractDocument.served {
            let responses = ContractDocument.responses(of: id)
            #expect(!responses.isEmpty, "\(id) has no responses")
            for (status, component) in responses {
                let decode = try #require(
                    Self.models[component], "no Swift model for \(component) (\(id) \(status))")
                let examples = ContractDocument.examples(of: component)
                #expect(!examples.isEmpty, "\(component) has no examples")
                for (index, example) in examples.enumerated() {
                    do {
                        try decode(ContractDocument.data(example))
                        decoded += 1
                    } catch {
                        Issue.record("\(id) \(status) \(component) example \(index): \(error)")
                    }
                }
            }
        }
        #expect(decoded > 110)
    }

    @Test("every reader's contract example decodes and keeps its required fields")
    func readerExamples() throws {
        let file = ContractDocument.folder.appendingPathComponent("readers.json")
        let document = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: file))
        let readers = try #require(document["readers"]?.arrayValue)
        #expect(readers.compactMap { $0["provider"]?.stringValue }.sorted() == Provider.allCases.map(\.rawValue).sorted())
        let schema = try #require(ContractDocument.schema("CredentialReading"))
        for reader in readers {
            let example = try #require(reader["example_reading"])
            let reading = try LeverageJSON.decoder().decode(CredentialReading.self, from: ContractDocument.data(example))
            let encoded = try LeverageJSON.encoder().encode(reading)
            let json = try JSONDecoder().decode(JSONValue.self, from: encoded)
            ClientPathsTests.expect(json, fits: schema, at: reader["provider"]?.stringValue ?? "reader")
            #expect(try LeverageJSON.decoder().decode(CredentialReading.self, from: encoded) == reading)
        }
    }

    @Test("a credentials list without a reading keeps the required null fields")
    func credentialsWithoutReading() throws {
        let example = try #require(ContractDocument.examples(of: "CredentialsList").first)
        let list = try LeverageJSON.decoder().decode(CredentialsList.self, from: ContractDocument.data(example))
        let credential = try #require(list.credentials.first?.credential)
        let row = CredentialWithReading(credential: credential)
        let withoutReading = CredentialsList(credentials: [row], asOfSeq: list.asOfSeq)
        let data = try LeverageJSON.encoder().encode(withoutReading)
        let written = try JSONDecoder().decode(JSONValue.self, from: data)
        let schema = try #require(ContractDocument.schema("CredentialsList"))
        ClientPathsTests.expect(written, fits: schema, at: "CredentialsList")
        #expect(try LeverageJSON.decoder().decode(CredentialsList.self, from: data) == withoutReading)
    }

    @Test("a token answer is the token the first time and repeated, with none, after",
          arguments: ["OwnerSessionCompleted", "HelperTokenIssuedCompleted",
                      "LandingPromptIssuedCompleted", "SeatTokenPickupCompleted"])
    func tokenAnswers(component: String) throws {
        let examples = ContractDocument.examples(of: component)
        #expect(examples.count == 2, "\(component) should show both shapes")
        var shapes: [String] = []
        for example in examples {
            let data = try ContractDocument.data(example)
            let decoder = LeverageJSON.decoder()
            let repeated = example["result"]?["repeated"]?.boolValue == true
            switch component {
            case "OwnerSessionCompleted":
                let answer = try decoder.decode(CommandOutcome<OwnerSessionAnswer>.self, from: data)
                switch try #require(answer.result) {
                case .shown(let session): #expect(!session.sessionToken.isEmpty); shapes.append("shown")
                case .repeated(let session): #expect(session.repeated); shapes.append("repeated")
                }
            case "HelperTokenIssuedCompleted":
                let answer = try decoder.decode(CommandOutcome<HelperTokenAnswer>.self, from: data)
                switch try #require(answer.result) {
                case .shown(let issued): #expect(!issued.helperToken.isEmpty); shapes.append("shown")
                case .repeated(let issued): #expect(issued.repeated); shapes.append("repeated")
                }
            case "LandingPromptIssuedCompleted":
                let answer = try decoder.decode(CommandOutcome<LandingPromptIssuedAnswer>.self, from: data)
                switch try #require(answer.result) {
                case .shown(let issued):
                    #expect(!issued.seatToken.isEmpty && issued.text.contains(issued.seatToken))
                    #expect(issued.connection == .http)
                    shapes.append("shown")
                case .repeated(let issued):
                    #expect(issued.repeated && issued.connection == .http)
                    let json = try JSONDecoder().decode(JSONValue.self, from: LeverageJSON.encoder().encode(issued))
                    #expect(json["seat_token"] == nil && json["text"] == nil)
                    shapes.append("repeated")
                }
            default:
                let answer = try decoder.decode(CommandOutcome<SeatTokenPickupAnswer>.self, from: data)
                switch try #require(answer.result) {
                case .shown(let pickup): #expect(!pickup.seatToken.isEmpty); shapes.append("shown")
                case .repeated(let pickup): #expect(pickup.repeated); shapes.append("repeated")
                }
            }
            #expect(shapes.last == (repeated ? "repeated" : "shown"))
        }
        #expect(shapes == ["shown", "repeated"])
    }

    @Test("seat connection returns just the seat ID")
    func seatConnected() throws {
        let fixture = try #require(ContractDocument.examples(of: "SeatConnectedCompleted").first)
        let answer = try LeverageJSON.decoder().decode(
            CommandOutcome<SeatConnected>.self, from: ContractDocument.data(fixture))
        let result = try #require(try answer.completedResult())
        #expect(result.seatID.contractString == fixture["result"]?["seat_id"]?.stringValue)
        let written = try JSONDecoder().decode(JSONValue.self, from: LeverageJSON.encoder().encode(result))
        #expect(written == fixture["result"])
    }

    @Test("the issued prompt's token and text are hidden when inspected")
    func issuedPromptHidesSecrets() throws {
        let issued = try example("LandingPromptIssued", as: LandingPromptIssued.self)
        try #require(!issued.seatToken.isEmpty && !issued.text.isEmpty)
        let mirror = Mirror(reflecting: issued)
        let labels = Set(mirror.children.compactMap(\.label))
        #expect(labels.isDisjoint(with: ["seatToken", "text"]))
        for display in [String(describing: issued), String(reflecting: issued)] {
            let revealsToken = display.contains(issued.seatToken)
            let revealsText = display.contains(issued.text)
            #expect(!revealsToken)
            #expect(!revealsText)
        }
    }

    @Test("a General briefing preserves null for its role file and version")
    func generalBriefing() throws {
        var briefing = try #require(ContractDocument.examples(of: "Briefing").first?.objectValue)
        var versions = try #require(briefing["versions"]?.objectValue)
        versions["role_file_version"] = .null
        briefing["versions"] = .object(versions)
        briefing["role_file"] = .null
        let model = try LeverageJSON.decoder().decode(Briefing.self, from: ContractDocument.data(.object(briefing)))
        let written = try JSONDecoder().decode(JSONValue.self, from: LeverageJSON.encoder().encode(model))
        #expect(written["role_file"] == .null)
        #expect(written["versions"]?["role_file_version"] == .null)
    }

    private static let materials: [String: @Sendable (JSONValue) throws -> JSONValue] = [
        "CheckMaterial": roundTrip(CheckMaterial.self),
        "DraftMaterial": roundTrip(DraftMaterial.self),
        "QuestionMaterial": roundTrip(QuestionMaterial.self),
        "ApprovalMaterial": roundTrip(ApprovalMaterial.self),
    ]

    private static func roundTrip<Model: Codable & SendableMetatype>(_ type: Model.Type)
        -> @Sendable (JSONValue) throws -> JSONValue {
        { example in
            let model = try LeverageJSON.decoder().decode(type, from: ContractDocument.data(example))
            return try JSONDecoder().decode(JSONValue.self, from: LeverageJSON.encoder().encode(model))
        }
    }

    @Test("General job material round-trips its null role file and rules", arguments: Self.materials.keys.sorted())
    func generalMaterial(component: String) throws {
        let roundTrip = try #require(Self.materials[component])
        let rules = JSONValue.array(SeatRole.general.jobRules.map(JSONValue.string))
        let example = try #require(ContractDocument.examples(of: component).first {
            $0["role_file"] == .null
        })
        let written = try roundTrip(example)
        #expect(written["role_file"] == .null)
        #expect(written["job_rules"] == rules)
    }

    @Test("material issued before job_rules was added reads with no rules", arguments: Self.materials.keys.sorted())
    func olderMaterial(component: String) throws {
        let roundTrip = try #require(Self.materials[component])
        var fields = try #require(ContractDocument.examples(of: component).first?.objectValue)
        fields.removeValue(forKey: "job_rules")
        let written = try roundTrip(.object(fields))
        #expect(written["role_file"] == fields["role_file"])
        #expect(written["job_rules"] == .array([]))
    }

    @Test("material with an explicit null job_rules is malformed", arguments: Self.materials.keys.sorted())
    func nullJobRules(component: String) throws {
        let roundTrip = try #require(Self.materials[component])
        var fields = try #require(ContractDocument.examples(of: component).first?.objectValue)
        fields["job_rules"] = .null
        #expect(throws: DecodingError.self) {
            _ = try roundTrip(.object(fields))
        }
    }

    @Test("draft material retains its required nullable values")
    func draftKeepsNulls() throws {
        let roundTrip = try #require(Self.materials["DraftMaterial"])
        let draft = try #require(ContractDocument.examples(of: "DraftMaterial").first)
        let written = try roundTrip(draft)
        for key in ["details", "work_reference", "minimum_strength_rank", "budget_cap"] {
            #expect(draft[key] == .null)
            #expect(written[key] == .null, "\(key)")
        }
    }

    @Test("each General job claim round-trips its material through the claim and its typed input",
          arguments: ["rule_check", "contract_draft", "question", "approval"])
    func generalClaim(kind: String) throws {
        let (inputName, materialName) = switch kind {
        case "rule_check": ("RuleCheckJobInput", "CheckMaterial")
        case "contract_draft": ("ContractDraftJobInput", "DraftMaterial")
        case "question": ("QuestionJobInput", "QuestionMaterial")
        default: ("ApprovalJobInput", "ApprovalMaterial")
        }
        let example = try #require(ContractDocument.examples(of: materialName).first {
            $0["role_file"] == .null
        })
        var fields = try #require(ContractDocument.examples(of: "ClaimJobResult").first?.objectValue)
        var input = try #require(ContractDocument.examples(of: inputName).first?.objectValue)
        input["material"] = example
        fields["input"] = .object(input)
        fields["kind"] = .string(kind)

        let claim = try LeverageJSON.decoder().decode(JobClaim.self, from: ContractDocument.data(.object(fields)))
        let written = try JSONDecoder().decode(JSONValue.self, from: LeverageJSON.encoder().encode(claim))
        let material = try #require(written["input"]?["material"])
        #expect(material["role_file"] == .null)
        #expect(material["job_rules"] == example["job_rules"])
        switch claim.input {
        case .ruleCheck, .contractDraft: break
        case .other(.question, _): #expect(claim.input.questionInput != nil)
        case .other(.approval, _): #expect(claim.input.approvalInput != nil)
        case .other: Issue.record("Unexpected job kind")
        }
    }

    @Test("an outcome keeps its kind, result and refusal")
    func outcomeFields() throws {
        let examples = ContractDocument.examples(of: "CommandOutcome")
        let outcomes = try examples.map {
            try LeverageJSON.decoder().decode(PlainOutcome.self, from: ContractDocument.data($0))
        }
        #expect(outcomes.map(\.outcome) == [.pending, .completed, .refused])
        #expect(outcomes[0].result == nil && outcomes[0].refusal == nil)
        #expect(outcomes[1].result?["lease_due_at"]?.stringValue == "2026-01-01T01:00:00Z")
        #expect(outcomes[2].refusal?.code == .criteriaIncomplete)
        #expect(outcomes[2].command == .submit)
    }

    @Test("dates are read with and without fractional seconds and an offset")
    func dates() throws {
        let decoder = LeverageJSON.decoder()
        for (text, seconds) in [
            ("2026-01-01T00:00:00Z", 1_767_225_600.0),
            ("2026-01-01T00:00:00.250Z", 1_767_225_600.25),
            ("2026-01-01T00:00:00.123456Z", 1_767_225_600.123456),
            ("2026-01-01T02:00:00+02:00", 1_767_225_600.0),
        ] {
            let result = try decoder.decode(
                HeartbeatResult.self, from: Data(#"{"lease_due_at":"\#(text)"}"#.utf8))
            #expect(abs(result.leaseDueAt.timeIntervalSince1970 - seconds) < 0.000_001, "\(text)")
        }
        #expect(throws: DecodingError.self) {
            try decoder.decode(HeartbeatResult.self, from: Data(#"{"lease_due_at":"soon"}"#.utf8))
        }
    }

    @Test("a date is written in UTC with its microseconds and read back the same")
    func dateRoundTrip() throws {
        let date = Date(timeIntervalSince1970: 1_767_225_600.123456)
        let text = LeverageJSON.string(from: date)
        #expect(text == "2026-01-01T00:00:00.123456Z")
        #expect(LeverageJSON.date(from: text) == date)
        #expect(LeverageJSON.string(from: Date(timeIntervalSince1970: 1_767_225_600)) == "2026-01-01T00:00:00Z")
    }

    /// Fields the Swift models read with a generated enum, and that enum's
    /// values: the interface schema's enum must equal them.
    static let enumFields: [(component: String, path: [String], values: [String])] = [
        ("TaskSummary", ["state"], TaskState.allCases.map(\.rawValue)),
        ("TaskSummary", ["priority"], Priority.allCases.map(\.rawValue)),
        ("Criterion", ["kind"], CriterionKind.allCases.map(\.rawValue)),
        ("Criterion", ["state"], CriterionState.allCases.map(\.rawValue)),
        ("Evidence", ["kind"], EvidenceKind.allCases.map(\.rawValue)),
        ("Action", ["kind"], ActionKind.allCases.map(\.rawValue)),
        ("Action", ["state"], ActionState.allCases.map(\.rawValue)),
        ("Action", ["approved_by_kind"], ActorKind.allCases.map(\.rawValue)),
        ("Review", ["verdict"], ReviewVerdict.allCases.map(\.rawValue)),
        ("Question", ["outcome"], QuestionOutcome.allCases.map(\.rawValue)),
        ("Question", ["basis"], QuestionBasis.allCases.map(\.rawValue)),
        ("BriefEntry", ["kind"], BriefEntryKind.allCases.map(\.rawValue)),
        ("BriefEntry", ["author_kind"], ActorKind.allCases.map(\.rawValue)),
        ("Hold", ["reason"], HoldReason.allCases.map(\.rawValue)),
        ("BoardTask", ["hold_reasons", "items"], HoldReason.allCases.map(\.rawValue)),
        ("InboxItem", ["kind"], NeedsYouItem.allCases.map(\.rawValue)),
        ("InboxItem", ["about_kind"], InboxAboutKind.allCases.map(\.rawValue)),
        ("InboxItem", ["choices", "items"], InboxChoice.allCases.map(\.rawValue)),
        ("InboxItem", ["state"], InboxState.allCases.map(\.rawValue)),
        ("Event", ["type"], EventType.allCases.map(\.rawValue)),
        ("Event", ["actor_kind"], ActorKind.allCases.map(\.rawValue)),
        ("Event", ["subject_kind"], EventSubjectKind.allCases.map(\.rawValue)),
        ("LogName", ["kind"], LogNameKind.allCases.map(\.rawValue)),
        ("NextItem", ["kind"], NextKind.allCases.map(\.rawValue)),
        ("Refusal", ["code"], RefusalCode.allCases.map(\.rawValue)),
        ("TransportError", ["error", "code"], TransportErrorCode.allCases.map(\.rawValue)),
        ("Seat", ["provider"], Provider.allCases.map(\.rawValue)),
        ("Seat", ["role"], SeatRole.allCases.map(\.rawValue)),
        ("Seat", ["run_state"], SeatRunState.allCases.map(\.rawValue)),
        ("Seat", ["run_stop_reason"], RunStopReason.allCases.map(\.rawValue)),
        ("RecoveryTime", ["kind"], RecoveryKind.allCases.map(\.rawValue)),
        ("RecoveryTime", ["ended_by"], RecoveryEndedBy.allCases.map(\.rawValue)),
        ("LimitReport", ["window"], LimitWindow.allCases.map(\.rawValue)),
        ("ChangeSeatRequest", ["role"], SeatRole.allCases.map(\.rawValue)),
        ("Credential", ["kind"], CredentialKind.allCases.map(\.rawValue)),
        ("Credential", ["provider"], Provider.allCases.map(\.rawValue)),
        ("Credential", ["state"], CredentialState.allCases.map(\.rawValue)),
        ("CredentialReading", ["state"], ReadingState.allCases.map(\.rawValue)),
        ("Figure", ["kind"], FigureKind.allCases.map(\.rawValue)),
        ("Figure", ["window"], LimitWindow.allCases.map(\.rawValue)),
        ("Reset", ["kind"], ResetKind.allCases.map(\.rawValue)),
        ("SystemHealth", ["orchestrator"], OrchestratorState.allCases.map(\.rawValue)),
        ("HelperRequest", ["kind"], HelperRequestKind.allCases.map(\.rawValue)),
        ("HelperRequest", ["state"], HelperRequestState.allCases.map(\.rawValue)),
        ("HelperRequestParams", ["provider"], Provider.allCases.map(\.rawValue)),
        ("HelperRequestParams", ["credential_kind"], CredentialKind.allCases.map(\.rawValue)),
        ("HelperRequestParams", ["role"], SeatRole.allCases.map(\.rawValue)),
        ("HelperCheckProgress", ["check"], HelperCheck.allCases.map(\.rawValue)),
        ("HelperCheckProgress", ["state"], HelperCheckState.allCases.map(\.rawValue)),
        ("HelperCheckProgress", ["failure"], HelperCheckFailure.allCases.map(\.rawValue)),
        ("HelperCheckResult", ["check"], HelperCheck.allCases.map(\.rawValue)),
        ("HelperCheckResult", ["failure"], HelperCheckFailure.allCases.map(\.rawValue)),
        ("HelperRequestResult", ["outcome"], HelperRequestOutcome.allCases.map(\.rawValue)),
        ("AddCredentialRequest", ["kind"], CredentialKind.allCases.map(\.rawValue)),
        ("AddCredentialRequest", ["provider"], Provider.allCases.map(\.rawValue)),
        ("ConnectSeatRequest", ["role"], SeatRole.allCases.map(\.rawValue)),
        ("ConnectSeatRequest", ["provider"], Provider.allCases.map(\.rawValue)),
        ("CriterionInput", ["kind"], CriterionKind.allCases.map(\.rawValue)),
        ("ActionInput", ["kind"], ActionKind.allCases.map(\.rawValue)),
        ("AddTaskRequest", ["priority"], Priority.allCases.map(\.rawValue)),
        ("GiveVerdictRequest", ["verdict"], ReviewVerdict.allCases.map(\.rawValue)),
        ("RunStoppedReport", ["stop_reason"], RunStopReason.allCases.map(\.rawValue)),
        ("PassCriterionRequest", ["evidence", "kind"], EvidenceKind.allCases.map(\.rawValue)),
        ("ReleaseTaskRequest", ["reason"],
         ReleaseReason.allCases.filter(\.isChosenBySeat).map(\.rawValue)),
        // The Rule checks milestone.
        ("RuleVersion", ["hook"], RuleHook.allCases.map(\.rawValue)),
        ("RuleVersion", ["kind"], RuleKind.allCases.map(\.rawValue)),
        ("RuleVersion", ["checker"], RuleChecker.allCases.map(\.rawValue)),
        ("RuleVersion", ["on_fail"], RuleOnFail.allCases.map(\.rawValue)),
        ("RuleVersion", ["route"], RuleRoute.allCases.map(\.rawValue)),
        ("RuleVersion", ["origin"], RuleOrigin.allCases.map(\.rawValue)),
        ("RuleVersion", ["author_kind"], ActorKind.allCases.map(\.rawValue)),
        ("RuleScope", ["kind"], RuleScopeKind.allCases.map(\.rawValue)),
        ("RuleScope", ["action_kinds", "items"], ActionKind.allCases.map(\.rawValue)),
        ("AddRuleRequest", ["hook"], RuleHook.allCases.filter(\.isCustomAllowed).map(\.rawValue)),
        ("SaveRuleRequest", ["on_fail"], RuleOnFail.allCases.map(\.rawValue)),
        ("SaveRuleRequest", ["route"], RuleRoute.allCases.map(\.rawValue)),
        ("TaskRuleCheck", ["hook"], RuleHook.allCases.map(\.rawValue)),
        ("TaskRuleCheck", ["checker"], RuleChecker.allCases.map(\.rawValue)),
        ("TaskRuleCheck", ["on_fail"], RuleOnFail.allCases.map(\.rawValue)),
        ("TaskRuleCheck", ["result"], CheckResult.allCases.map(\.rawValue)),
        ("TaskRuleCheck", ["effect"], RuleEffect.allCases.map(\.rawValue)),
        ("TaskStep", ["kind"], StepKind.allCases.map(\.rawValue)),
        ("TaskStep", ["step_class"], StepClass.allCases.map(\.rawValue)),
        ("TaskStep", ["subject_kind"], StepSubjectKind.allCases.map(\.rawValue)),
        ("TaskStep", ["cause_kind"], StepCauseKind.allCases.map(\.rawValue)),
        ("TaskPage", ["draft"], DraftState.allCases.map(\.rawValue)),
        ("RuleCheckJobInput", ["hook"], RuleHook.allCases.map(\.rawValue)),
        ("RuleCheckJobResult", ["result"], CheckVerdict.allCases.map(\.rawValue)),
        ("ClaimJobResult", ["kind"], JobKind.allCases.map(\.rawValue)),
        ("QuotedText", ["label"], QuotedLabel.allCases.map(\.rawValue)),
        ("CheckContract", ["criteria", "items", "kind"], CriterionKind.allCases.map(\.rawValue)),
        ("CheckContract", ["criteria", "items", "state"], CriterionState.allCases.map(\.rawValue)),
    ]

    @Test("every enum the models read equals the interface schema's")
    func enumsMatchTheSchema() throws {
        for (component, path, values) in Self.enumFields {
            // Each name is a property, except "items", an array's items.
            let field = "\(component).\(path.joined(separator: "."))"
            var node = try #require(ContractDocument.schema(component), "\(component)")
            for key in path {
                let next = key == "items" ? node["items"] : node["properties"]?[key]
                node = try #require(next, "\(field)")
                if let reference = node["$ref"]?.stringValue {
                    let prefix = "#/components/schemas/"
                    try #require(reference.hasPrefix(prefix), "\(field): \(reference)")
                    let name = String(reference.dropFirst(prefix.count))
                    node = try #require(ContractDocument.schema(name), "\(field): \(reference)")
                }
            }
            let schemaValues = (node["enum"]?.arrayValue ?? []).compactMap(\.stringValue)
            #expect(schemaValues == values, "\(field)")
        }
        let commandNames = (ContractDocument.schema("CommandName")?["enum"]?.arrayValue ?? [])
            .compactMap(\.stringValue)
        #expect(commandNames == CommandName.allCases.map(\.rawValue))
        let addTaskStates = (ContractDocument.schema("AddTaskRequest")?["properties"]?["state"]?[
            "enum"]?.arrayValue ?? []).compactMap(\.stringValue)
        #expect(addTaskStates.allSatisfy { TaskState(rawValue: $0) != nil } && !addTaskStates.isEmpty)
    }

    // What the Handoff milestone added to the reads (plan section 2.3).

    private func example<Model: Decodable & SendableMetatype>(
        _ component: String, as type: Model.Type, at index: Int = 0
    ) throws -> Model {
        let examples = ContractDocument.examples(of: component)
        let example = try #require(examples.indices.contains(index) ? examples[index] : nil, "\(component)[\(index)]")
        return try LeverageJSON.decoder().decode(Model.self, from: ContractDocument.data(example))
    }

    @Test("a credential reads when its limit was reported")
    func credentialLimitedSince() throws {
        let credential = try example("Credential", as: Credential.self)
        #expect(credential.limitedSince == LeverageJSON.date(from: "2026-01-01T00:00:00Z"))
        #expect(credential.limitedUntil == LeverageJSON.date(from: "2026-01-01T00:00:00Z"))
    }

    @Test("a seat reads the account its run is on and why its last run ended")
    func seatRun() throws {
        let seat = try example("Seat", as: Seat.self)
        #expect(seat.runCredentialID == UUID(uuidString: "00000000-0000-4000-8000-000000000144"))
        #expect(seat.runStopReason == nil)
        let stopped = Data("""
            {"id":"00000000-0000-4000-8000-000000000001","name":"Made-up","provider":"claude","model":null,
             "effort":null,"role":"builder","strength_rank":null,"credential_id":null,"enabled":true,
             "paused":false,"last_polled_at":null,"run_state":"stopped","removed_at":null,
             "wanted_running":true,"run_credential_id":null,"run_stop_reason":"signed_out"}
            """.utf8)
        let again = try LeverageJSON.decoder().decode(Seat.self, from: stopped)
        #expect(again.runStopReason == .signedOut && again.runCredentialID == nil)
    }

    @Test("a task page reads its recovery times in the server's order")
    func taskPageRecoveryTimes() throws {
        // The page's own example has none: it carries the two examples of
        // the component instead.
        var page = try #require(ContractDocument.examples(of: "TaskPage").first?.objectValue)
        #expect(page["recovery_times"] != nil)
        page["recovery_times"] = .array(ContractDocument.examples(of: "RecoveryTime"))
        let read = try LeverageJSON.decoder().decode(
            TaskPage.self, from: ContractDocument.data(.object(page)))
        let times = read.recoveryTimes
        #expect(times.count == 2)
        let handoff = try #require(times.first)
        #expect(handoff.kind == .limit && handoff.endedBy == .handoff && handoff.seconds == 0)
        #expect(handoff.reviewID == nil)
        let open = try #require(times.last)
        #expect(open.kind == .signedOut && open.endedBy == nil && open.endedAt == nil && open.seconds == 300)
        #expect(try example("TaskPage", as: TaskPage.self).recoveryTimes.isEmpty)
    }

    @Test("a task page reads the account its task waits for and when it resets, or none (HE-15, HE-16)")
    func taskPageWaiting() throws {
        let read = try example("TaskPage", as: TaskPage.self)
        #expect(read.waitingForCredentialID == UUID(uuidString: "00000000-0000-4000-8000-000000000314"))
        #expect(read.waitingUntil == LeverageJSON.date(from: "2026-01-01T00:00:00Z"))
        var page = try #require(ContractDocument.examples(of: "TaskPage").first?.objectValue)
        page["waiting_for_credential_id"] = .null
        page["waiting_until"] = .null
        let none = try LeverageJSON.decoder().decode(TaskPage.self, from: ContractDocument.data(.object(page)))
        #expect(none.waitingForCredentialID == nil && none.waitingUntil == nil)
    }

    @Test("the system health reads when the last backup was made and whether it is late")
    func healthBackup() throws {
        let health = try example("SystemHealth", as: SystemHealth.self)
        #expect(health.backupLastRanAt == LeverageJSON.date(from: "2026-01-01T00:00:00Z"))
        #expect(health.backupLate == false)
        let late = Data("""
            {"sweep_last_ran_at":null,"sweep_late":true,"helper_last_reported_at":null,
             "queued_helper_requests":0,"ready_tasks":0,"waiting_reviews":0,"orchestrator":"not_set_up",
             "backup_last_ran_at":null,"backup_late":true,"waiting_checks":2}
            """.utf8)
        let again = try LeverageJSON.decoder().decode(SystemHealth.self, from: late)
        #expect(again.backupLastRanAt == nil && again.backupLate && again.waitingChecks == 2)
    }

    @Test("a start request carries the task or review its run continues")
    func startRequestParams() throws {
        let params = try example("HelperRequestParams", as: HelperRequestParams.self, at: 2)
        #expect(params.taskID == UUID(uuidString: "00000000-0000-4000-8000-000000000311"))
        #expect(params.reviewID == nil)
        let review = try LeverageJSON.decoder().decode(
            HelperRequestParams.self,
            from: Data(#"{"role":"reviewer","review_id":"00000000-0000-4000-8000-000000000999"}"#.utf8))
        #expect(review.reviewID == UUID(uuidString: "00000000-0000-4000-8000-000000000999") && review.taskID == nil)
    }

    @Test("an inbox page reads its items and the position to ask from next")
    func inboxPage() throws {
        let page = try example("InboxPage", as: InboxPage.self)
        #expect(page.items.count == 1 && page.nextAfterSeq == 1)
        #expect(page.items[0].kind == .questionPassedOn && page.items[0].openedSeq == 1)
    }

    /// Every field the contract names is one the models keep: what a model
    /// writes back has each key of the example that holds a value, and no key
    /// the schema lacks.
    static let roundTrips: [(component: String, check: @Sendable (Data) throws -> Set<String>)] = [
        ("Credential", keys(of: Credential.self)),
        ("Seat", keys(of: Seat.self)),
        ("SystemHealth", keys(of: SystemHealth.self)),
        ("RecoveryTime", keys(of: RecoveryTime.self)),
        ("HelperRequestParams", keys(of: HelperRequestParams.self)),
        ("InboxPage", keys(of: InboxPage.self)),
        ("Rule", keys(of: RuleRecord.self)),
        ("RuleVersion", keys(of: RuleVersion.self)),
        ("RuleScope", keys(of: RuleScope.self)),
        ("RuleStats", keys(of: RuleStats.self)),
        ("RuleWithVersion", keys(of: RuleRow.self)),
        ("RulesList", keys(of: RulesList.self)),
        ("TaskRuleCheck", keys(of: RuleCheckRow.self)),
        ("RuleCheckAttempt", keys(of: CheckAttempt.self)),
        ("TaskStep", keys(of: TaskStepRow.self)),
        ("PendingCommand", keys(of: PendingState.self)),
        ("TaskPage", keys(of: TaskPage.self)),
        ("BoardTask", keys(of: BoardTask.self)),
        ("CheckMaterial", keys(of: CheckMaterial.self)),
        ("CheckContract", keys(of: CheckContract.self)),
        ("QuotedText", keys(of: QuotedText.self)),
        ("DraftMaterial", keys(of: DraftMaterial.self)),
        ("RuleCheckJobInput", keys(of: RuleCheckJobInput.self)),
        ("ContractDraftJobInput", keys(of: ContractDraftJobInput.self)),
        ("ClaimJobResult", keys(of: JobClaim.self)),
        ("DraftContractResult", keys(of: DraftContractResult.self)),
        ("RuleCheckJobResult", keys(of: RuleCheckVerdict.self)),
    ]

    private static func keys<Model: Codable & SendableMetatype>(of type: Model.Type)
        -> @Sendable (Data) throws -> Set<String> {
        { data in
            let model = try LeverageJSON.decoder().decode(Model.self, from: data)
            let written = try LeverageJSON.encoder().encode(model)
            let object = try JSONDecoder().decode(JSONValue.self, from: written)
            return Set(object.objectValue?.keys.map { $0 } ?? [])
        }
    }

    @Test("a model keeps every field of its schema and writes no other", arguments: [
        "Credential", "Seat", "SystemHealth", "RecoveryTime", "HelperRequestParams", "InboxPage",
        "Rule", "RuleVersion", "RuleScope", "RuleStats", "RuleWithVersion", "RulesList", "TaskRuleCheck",
        "RuleCheckAttempt", "TaskStep", "PendingCommand", "TaskPage", "BoardTask", "CheckMaterial",
        "CheckContract", "QuotedText", "DraftMaterial", "RuleCheckJobInput", "ContractDraftJobInput",
        "ClaimJobResult", "DraftContractResult", "RuleCheckJobResult",
    ])
    func modelsKeepEveryField(component: String) throws {
        let entry = try #require(Self.roundTrips.first { $0.component == component })
        let properties = Set(try #require(ContractDocument.schema(component)?["properties"]?.objectValue).keys)
        for (index, example) in ContractDocument.examples(of: component).enumerated() {
            let withValues = Set((example.objectValue ?? [:]).filter { $0.value != .null }.keys)
            let written = try entry.check(ContractDocument.data(example))
            #expect(withValues.isSubset(of: written), "\(component)[\(index)] lost \(withValues.subtracting(written))")
            #expect(written.isSubset(of: properties), "\(component)[\(index)] wrote \(written.subtracting(properties))")
        }
    }
}
