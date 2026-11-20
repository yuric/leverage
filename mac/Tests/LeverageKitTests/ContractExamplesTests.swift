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

    /// The operations milestone 2 serves (plan section 2.3): 16 agent calls,
    /// the health check, 21 owner calls, 5 helper calls and the six
    /// additions.
    static let served: [String] = [
        "get_next", "get_command", "claim_next_task", "get_task_briefing",
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
        "report_request_progress", "get_landing_prompt",
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
        "SeatConnectedCompleted": decodes(CommandOutcome<SeatConnectedAnswer>.self),
        "SeatTokenPickupCompleted": decodes(CommandOutcome<SeatTokenPickupAnswer>.self),
        "BriefingResponse": decodes(BriefingResponse.self),
        "Health": decodes(Health.self),
        "EventsPage": decodes(EventsPage.self),
        "Board": decodes(Board.self),
        "TaskPage": decodes(TaskPage.self),
        "SeatsList": decodes(SeatsList.self),
        "CredentialsList": decodes(CredentialsList.self),
        "SystemHealth": decodes(SystemHealth.self),
        "HelperNext": decodes(HelperNext.self),
        "HelperRequestStatus": decodes(HelperRequestStatus.self),
        "SetupState": decodes(SetupState.self),
        "LandingPrompt": decodes(LandingPrompt.self),
        "TransportError": decodes(TransportError.self),
        "Refusal": decodes(Refusal.self),
    ]

    @Test("every served operation is in the registry and the interface schema")
    func servedOperationsExist() {
        #expect(ContractDocument.served.count == 48)
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
        #expect(decoded > 100)
    }

    @Test("a token answer is the token the first time and repeated, with none, after",
          arguments: ["OwnerSessionCompleted", "HelperTokenIssuedCompleted",
                      "SeatConnectedCompleted", "SeatTokenPickupCompleted"])
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
            case "SeatConnectedCompleted":
                let answer = try decoder.decode(CommandOutcome<SeatConnectedAnswer>.self, from: data)
                switch try #require(answer.result) {
                case .shown: shapes.append("shown")
                case .repeated(let connected): #expect(connected.repeated); shapes.append("repeated")
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
    ]

    @Test("every enum the models read equals the interface schema's")
    func enumsMatchTheSchema() throws {
        for (component, path, values) in Self.enumFields {
            // Each name is a property, except "items", an array's items.
            var node = try #require(ContractDocument.schema(component), "\(component)")
            for key in path {
                let next = key == "items" ? node["items"] : node["properties"]?[key]
                node = try #require(next, "\(component).\(path.joined(separator: "."))")
            }
            let schemaValues = (node["enum"]?.arrayValue ?? []).compactMap(\.stringValue)
            #expect(schemaValues == values, "\(component).\(path.joined(separator: "."))")
        }
        let commandNames = (ContractDocument.schema("CommandName")?["enum"]?.arrayValue ?? [])
            .compactMap(\.stringValue)
        #expect(commandNames == CommandName.allCases.map(\.rawValue))
        let addTaskStates = (ContractDocument.schema("AddTaskRequest")?["properties"]?["state"]?[
            "enum"]?.arrayValue ?? []).compactMap(\.stringValue)
        #expect(addTaskStates.allSatisfy { TaskState(rawValue: $0) != nil } && !addTaskStates.isEmpty)
    }
}
