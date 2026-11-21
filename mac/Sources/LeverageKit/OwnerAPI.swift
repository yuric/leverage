import Foundation

/// The owner's calls, one method per served operation. The
/// app's view models take `any OwnerAPI`: `OwnerClient` sends them over
/// HTTP, and LeverageTestSupport's `FakeOwnerAPI` answers them in memory.
///
/// Every command takes its `IdempotencyKey`: a new one per command, and the
/// same one when the same command is sent again (Retry, MA-16).
public protocol OwnerAPI: Sendable {
    // Setup and sign-in (public, then the owner's session).

    /// `get_setup_state`: whether an owner exists (no sign-in).
    func setupState() async throws -> SetupState
    /// `create_owner`: the workspace, the owner and a session, once (no sign-in).
    func createOwner(_ request: SignInRequest, key: IdempotencyKey) async throws -> CommandOutcome<OwnerSessionAnswer>
    /// `sign_in_owner`: a new session.
    func signIn(_ request: SignInRequest, key: IdempotencyKey) async throws -> CommandOutcome<OwnerSessionAnswer>
    /// `sign_out_owner`: ends this session.
    func signOut(key: IdempotencyKey) async throws -> PlainOutcome
    /// `get_owner_command`: a command's outcome by its key.
    func command(key: IdempotencyKey) async throws -> PlainOutcome

    // Reads.

    /// `list_events`: events after `afterSeq`; with `wait`, a long poll.
    func events(afterSeq: Int, limit: Int?, wait: Int?) async throws -> EventsPage
    /// `get_board`.
    func board() async throws -> Board
    /// `get_task`.
    func task(id: UUID) async throws -> TaskPage
    /// `list_seats`.
    func seats() async throws -> SeatsList
    /// `list_credentials`.
    func credentials() async throws -> CredentialsList
    /// `get_system_health`.
    func systemHealth() async throws -> SystemHealth
    /// `get_helper_request`: with `wait` and `changedAfter`, answers when
    /// the request changed after that time or when the wait runs out.
    func helperRequest(id: UUID, wait: Int?, changedAfter: Date?) async throws -> HelperRequestStatus
    /// `get_landing_prompt`: for a seat that connects on its own; a seat
    /// the app runs throws `LeverageClientError.refused` (`invalid_state`).
    func landingPrompt(seatID: UUID) async throws -> LandingPrompt
    /// `list_inbox`: the open Needs you items whose `inbox.opened` is after
    /// `afterSeq`; with `wait`, a long poll that answers when one opens.
    func listInbox(afterSeq: Int?, wait: Int?) async throws -> InboxPage

    // Tasks.

    /// `add_task`.
    func addTask(_ request: AddTaskRequest, key: IdempotencyKey) async throws -> CommandOutcome<TaskCreatedResult>
    /// `complete_contract`.
    func completeContract(taskID: UUID, _ request: CompleteContractRequest, key: IdempotencyKey) async throws
        -> PlainOutcome
    /// `cancel_task`.
    func cancelTask(taskID: UUID, key: IdempotencyKey) async throws -> PlainOutcome
    /// `allow_another_round`.
    func allowAnotherRound(taskID: UUID, key: IdempotencyKey) async throws -> PlainOutcome
    /// `promote_task`: an idea moves to Backlog (HM-45: "Move to Backlog").
    func promoteTask(taskID: UUID, key: IdempotencyKey) async throws -> PlainOutcome
    /// `edit_contract`: the form's values sent again (HM-49).
    func editContract(taskID: UUID, _ request: CompleteContractRequest, key: IdempotencyKey) async throws
        -> PlainOutcome
    /// `hold_task`: "Pause this task" (HM-45).
    func holdTask(taskID: UUID, key: IdempotencyKey) async throws -> PlainOutcome
    /// `resume_task`: "Continue this task" (HM-45).
    func resumeTask(taskID: UUID, key: IdempotencyKey) async throws -> PlainOutcome

    // Seats.

    /// `connect_seat`: a seat that connects on its own gets its token once.
    func connectSeat(_ request: ConnectSeatRequest, key: IdempotencyKey) async throws
        -> CommandOutcome<SeatConnectedAnswer>
    /// `start_seat`; the result's `helperRequestID` is the request to follow.
    func startSeat(seatID: UUID, key: IdempotencyKey) async throws -> PlainOutcome
    /// `stop_seat`.
    func stopSeat(seatID: UUID, key: IdempotencyKey) async throws -> PlainOutcome
    /// `remove_seat`.
    func removeSeat(seatID: UUID, key: IdempotencyKey) async throws -> PlainOutcome
    /// `pause_seat`.
    func pauseSeat(seatID: UUID, key: IdempotencyKey) async throws -> PlainOutcome
    /// `resume_seat`.
    func resumeSeat(seatID: UUID, key: IdempotencyKey) async throws -> PlainOutcome
    /// `change_seat`: only the fields the request sets change (HM-51).
    func changeSeat(seatID: UUID, _ request: ChangeSeatRequest, key: IdempotencyKey) async throws
        -> PlainOutcome

    // The helper and credentials.

    /// `issue_helper_token`.
    func issueHelperToken(name: String, key: IdempotencyKey) async throws -> CommandOutcome<HelperTokenAnswer>
    /// `add_credential`.
    func addCredential(_ request: AddCredentialRequest, key: IdempotencyKey) async throws
        -> CommandOutcome<AddCredentialResult>
    /// `verify_credential`; the result's `helperRequestID` is the request to follow.
    func verifyCredential(credentialID: UUID, key: IdempotencyKey) async throws -> PlainOutcome
    /// `sign_in_again`; the result's `helperRequestID` is the request to
    /// follow (HE-36). Refused for anything but an added login.
    func signInAgain(credentialID: UUID, key: IdempotencyKey) async throws -> PlainOutcome
    /// `install_tool`, after the owner confirmed.
    func installTool(provider: Provider, key: IdempotencyKey) async throws -> PlainOutcome

    // Rules and their checks (milestone 4).

    /// `list_rules`: the rules with their current versions, in order.
    func listRules() async throws -> RulesList
    /// `add_rule`: a custom rule.
    func addRule(_ request: AddRuleRequest, key: IdempotencyKey) async throws -> PlainOutcome
    /// `save_rule`: a new immutable version.
    func saveRule(ruleID: UUID, _ request: SaveRuleRequest, key: IdempotencyKey) async throws -> PlainOutcome
    /// `enable_rule`.
    func enableRule(ruleID: UUID, key: IdempotencyKey) async throws -> PlainOutcome
    /// `disable_rule`: also withdraws the rule's checks in flight.
    func disableRule(ruleID: UUID, key: IdempotencyKey) async throws -> PlainOutcome
    /// `revert_rule`: a shipped rule's own fields, as a new version.
    func revertRule(ruleID: UUID, key: IdempotencyKey) async throws -> PlainOutcome
    /// `remove_rule`: a custom rule only.
    func removeRule(ruleID: UUID, key: IdempotencyKey) async throws -> PlainOutcome
    /// `rerun_check`: "Run it again".
    func rerunCheck(checkID: UUID, key: IdempotencyKey) async throws -> PlainOutcome
    /// `override_check`: "Let it through once", with the owner's reason.
    func overrideCheck(checkID: UUID, _ request: OverrideCheckRequest, key: IdempotencyKey) async throws
        -> PlainOutcome
    /// `draft_contract`: "Draft the details"; the result is the planner job
    /// it queued.
    func draftContract(taskID: UUID, key: IdempotencyKey) async throws -> CommandOutcome<DraftContractResult>

    // Questions and approvals, projects, and workspace settings.

    /// `list_decisions`.
    func listDecisions() async throws -> DecisionsList
    /// `list_projects`.
    func listProjects() async throws -> ProjectsList
    /// `create_project`.
    func createProject(_ request: CreateProjectRequest, key: IdempotencyKey) async throws -> PlainOutcome
    /// `edit_brief`.
    func editBrief(projectID: UUID, _ request: EditBriefRequest, key: IdempotencyKey) async throws -> PlainOutcome
    /// `pause_project`.
    func pauseProject(projectID: UUID, key: IdempotencyKey) async throws -> PlainOutcome
    /// `resume_project`.
    func resumeProject(projectID: UUID, key: IdempotencyKey) async throws -> PlainOutcome
    /// `delete_project_content`.
    func deleteProjectContent(projectID: UUID, key: IdempotencyKey) async throws -> PlainOutcome
    /// `change_budget`.
    func changeBudget(projectID: UUID, _ request: ChangeBudgetRequest, key: IdempotencyKey) async throws
        -> PlainOutcome
    /// `change_task_priority`.
    func changeTaskPriority(taskID: UUID, _ request: ChangeTaskPriorityRequest, key: IdempotencyKey) async throws
        -> PlainOutcome
    /// `change_task_project`.
    func changeTaskProject(taskID: UUID, _ request: ChangeTaskProjectRequest, key: IdempotencyKey) async throws
        -> PlainOutcome
    /// `change_task_cap`.
    func changeTaskCap(taskID: UUID, _ request: ChangeTaskCapRequest, key: IdempotencyKey) async throws
        -> PlainOutcome
    /// `return_for_rework`.
    func returnForRework(taskID: UUID, _ request: ReturnForReworkRequest, key: IdempotencyKey) async throws
        -> PlainOutcome
    /// `offer_task_again`.
    func offerTaskAgain(taskID: UUID, key: IdempotencyKey) async throws -> PlainOutcome
    /// `grant_access`.
    func grantAccess(taskID: UUID, key: IdempotencyKey) async throws -> PlainOutcome
    /// `delete_task_content`.
    func deleteTaskContent(taskID: UUID, key: IdempotencyKey) async throws -> PlainOutcome
    /// `answer_question`.
    func answerQuestion(questionID: UUID, _ request: AnswerQuestionRequest, key: IdempotencyKey) async throws
        -> PlainOutcome
    /// `overturn_answer`.
    func overturnAnswer(questionID: UUID, key: IdempotencyKey) async throws -> PlainOutcome
    /// `approve_action`.
    func approveAction(actionID: UUID, key: IdempotencyKey) async throws -> PlainOutcome
    /// `stop_action`.
    func stopAction(actionID: UUID, key: IdempotencyKey) async throws -> PlainOutcome
    /// `waive_action`.
    func waiveAction(actionID: UUID, key: IdempotencyKey) async throws -> PlainOutcome
    /// `mark_action_done`.
    func markActionDone(actionID: UUID, key: IdempotencyKey) async throws -> PlainOutcome
    /// `overturn_approval`.
    func overturnApproval(actionID: UUID, key: IdempotencyKey) async throws -> PlainOutcome
    /// `change_workspace_settings`.
    func changeWorkspaceSettings(_ request: ChangeWorkspaceSettingsRequest, key: IdempotencyKey) async throws
        -> CommandOutcome<WorkspaceSettings>
    /// `get_workspace_settings`.
    func workspaceSettings() async throws -> WorkspaceSettings
    /// `get_landing_prompt` in the selected connection form.
    func landingPrompt(seatID: UUID, connection: LandingPromptConnection) async throws -> LandingPrompt
}

extension OwnerAPI {
    /// `issueHelperToken` for the app services (`HelperTokenIssuing`): the
    /// token from the first answer, nil from a repeated one; a refused or
    /// pending command throws.
    public func issueHelperToken(name: String, idempotencyKey: String) async throws -> String? {
        guard let key = IdempotencyKey(idempotencyKey) else {
            throw LeverageClientError.invalidKey(idempotencyKey)
        }
        switch try await issueHelperToken(name: name, key: key).completedResult() {
        case .shown(let issued): return issued.helperToken
        case .repeated, nil: return nil
        }
    }
}
