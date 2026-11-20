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

    /// The operations served so far: milestone 2's 48 (16 agent calls, the
    /// health check, 21 owner calls, 5 helper calls and six additions),
    /// milestone 3's eleven and, last, the twelve of the Rule checks
    /// milestone.
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
        // Milestone 3 (Handoff, plan section 2.3).
        "report_limit", "report_signed_out", "sign_in_again", "list_inbox", "promote_task",
        "edit_contract", "hold_task", "resume_task", "pause_seat", "resume_seat", "change_seat",
        // Milestone 4 (Rule checks, plan section 2.3).
        "claim_next_job", "submit_job_result", "list_rules", "add_rule", "save_rule", "enable_rule",
        "disable_rule", "revert_rule", "remove_rule", "rerun_check", "override_check", "draft_contract",
    ]

    /// The twelve operations the Rule checks milestone serves.
    static let ruleChecks: [String] = Array(served.suffix(12))

    /// The eleven operations the Handoff milestone serves.
    static let handoff: [String] = Array(served.dropLast(12).suffix(11))

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
        "ClaimNextJobCompleted": decodes(CommandOutcome<JobClaim>.self),
        "DraftContractCompleted": decodes(CommandOutcome<DraftContractResult>.self),
        "RulesList": decodes(RulesList.self),
        "InboxPage": decodes(InboxPage.self),
        "HelperNext": decodes(HelperNext.self),
        "HelperRequestStatus": decodes(HelperRequestStatus.self),
        "SetupState": decodes(SetupState.self),
        "LandingPrompt": decodes(LandingPrompt.self),
        "TransportError": decodes(TransportError.self),
        "Refusal": decodes(Refusal.self),
    ]

    @Test("every served operation is in the registry and the interface schema")
    func servedOperationsExist() {
        #expect(ContractDocument.served.count == 71)
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
