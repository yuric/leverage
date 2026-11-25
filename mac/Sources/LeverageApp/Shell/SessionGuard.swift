import Foundation
import LeverageKit

/// An `OwnerAPI` that lets every call through unchanged, and tells the app
/// when one of them answers 401: the session ended, so the app returns to
/// the sign-in screen (MA-6). The error is still thrown to the caller, so a
/// view model can show its own signed-out state.
///
/// The sign-in screen's own calls do not go through this: a wrong password
/// is a 401 too.
struct SessionGuard: OwnerAPI {
    let base: any OwnerAPI
    let onUnauthenticated: @MainActor @Sendable () -> Void

    private func guarded<T: Sendable>(_ call: () async throws -> T) async throws -> T {
        do {
            return try await call()
        } catch let error as TransportError where error.code == .unauthenticated {
            await onUnauthenticated()
            throw error
        }
    }

    func setupState() async throws -> SetupState { try await guarded { try await base.setupState() } }

    func createOwner(_ request: SignInRequest, key: IdempotencyKey) async throws
        -> CommandOutcome<OwnerSessionAnswer> {
        try await guarded { try await base.createOwner(request, key: key) }
    }

    func signIn(_ request: SignInRequest, key: IdempotencyKey) async throws -> CommandOutcome<OwnerSessionAnswer> {
        try await guarded { try await base.signIn(request, key: key) }
    }

    func signOut(key: IdempotencyKey) async throws -> PlainOutcome {
        try await guarded { try await base.signOut(key: key) }
    }

    func ownerIdentity() async throws -> OwnerSessionIdentity {
        try await guarded { try await base.ownerIdentity() }
    }

    func command(key: IdempotencyKey) async throws -> PlainOutcome {
        try await guarded { try await base.command(key: key) }
    }

    func events(afterSeq: Int, limit: Int?, wait: Int?) async throws -> EventsPage {
        try await guarded { try await base.events(afterSeq: afterSeq, limit: limit, wait: wait) }
    }

    func board() async throws -> Board { try await guarded { try await base.board() } }

    func task(id: UUID) async throws -> TaskPage { try await guarded { try await base.task(id: id) } }

    func seats() async throws -> SeatsList { try await guarded { try await base.seats() } }

    func credentials() async throws -> CredentialsList { try await guarded { try await base.credentials() } }

    func systemHealth() async throws -> SystemHealth { try await guarded { try await base.systemHealth() } }

    func helperRequest(id: UUID, wait: Int?, changedAfter: Date?) async throws -> HelperRequestStatus {
        try await guarded { try await base.helperRequest(id: id, wait: wait, changedAfter: changedAfter) }
    }

    func addTask(_ request: AddTaskRequest, key: IdempotencyKey) async throws -> CommandOutcome<TaskCreatedResult> {
        try await guarded { try await base.addTask(request, key: key) }
    }

    func completeContract(taskID: UUID, _ request: CompleteContractRequest, key: IdempotencyKey) async throws
        -> PlainOutcome {
        try await guarded { try await base.completeContract(taskID: taskID, request, key: key) }
    }

    func cancelTask(taskID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await guarded { try await base.cancelTask(taskID: taskID, key: key) }
    }

    func allowAnotherRound(taskID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await guarded { try await base.allowAnotherRound(taskID: taskID, key: key) }
    }

    func connectSeat(_ request: ConnectSeatRequest, key: IdempotencyKey) async throws
        -> CommandOutcome<SeatConnected> {
        try await guarded { try await base.connectSeat(request, key: key) }
    }

    func startSeat(seatID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await guarded { try await base.startSeat(seatID: seatID, key: key) }
    }

    func stopSeat(seatID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await guarded { try await base.stopSeat(seatID: seatID, key: key) }
    }

    func removeSeat(seatID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await guarded { try await base.removeSeat(seatID: seatID, key: key) }
    }

    func issueHelperToken(name: String, key: IdempotencyKey) async throws -> CommandOutcome<HelperTokenAnswer> {
        try await guarded { try await base.issueHelperToken(name: name, key: key) }
    }

    func addCredential(_ request: AddCredentialRequest, key: IdempotencyKey) async throws
        -> CommandOutcome<AddCredentialResult> {
        try await guarded { try await base.addCredential(request, key: key) }
    }

    func verifyCredential(credentialID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await guarded { try await base.verifyCredential(credentialID: credentialID, key: key) }
    }

    func installTool(provider: Provider, key: IdempotencyKey) async throws -> PlainOutcome {
        try await guarded { try await base.installTool(provider: provider, key: key) }
    }

    // The Handoff milestone's calls.

    func listInbox(afterSeq: Int?, wait: Int?) async throws -> InboxPage {
        try await guarded { try await base.listInbox(afterSeq: afterSeq, wait: wait) }
    }

    func promoteTask(taskID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await guarded { try await base.promoteTask(taskID: taskID, key: key) }
    }

    func editContract(taskID: UUID, _ request: CompleteContractRequest, key: IdempotencyKey) async throws
        -> PlainOutcome {
        try await guarded { try await base.editContract(taskID: taskID, request, key: key) }
    }

    func holdTask(taskID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await guarded { try await base.holdTask(taskID: taskID, key: key) }
    }

    func resumeTask(taskID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await guarded { try await base.resumeTask(taskID: taskID, key: key) }
    }

    func pauseSeat(seatID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await guarded { try await base.pauseSeat(seatID: seatID, key: key) }
    }

    func resumeSeat(seatID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await guarded { try await base.resumeSeat(seatID: seatID, key: key) }
    }

    func changeSeat(seatID: UUID, _ request: ChangeSeatRequest, key: IdempotencyKey) async throws
        -> PlainOutcome {
        try await guarded { try await base.changeSeat(seatID: seatID, request, key: key) }
    }

    func signInAgain(credentialID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await guarded { try await base.signInAgain(credentialID: credentialID, key: key) }
    }

    // The Rule checks milestone's calls.

    func listRules() async throws -> RulesList { try await guarded { try await base.listRules() } }

    func addRule(_ request: AddRuleRequest, key: IdempotencyKey) async throws -> PlainOutcome {
        try await guarded { try await base.addRule(request, key: key) }
    }

    func saveRule(ruleID: UUID, _ request: SaveRuleRequest, key: IdempotencyKey) async throws -> PlainOutcome {
        try await guarded { try await base.saveRule(ruleID: ruleID, request, key: key) }
    }

    func enableRule(ruleID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await guarded { try await base.enableRule(ruleID: ruleID, key: key) }
    }

    func disableRule(ruleID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await guarded { try await base.disableRule(ruleID: ruleID, key: key) }
    }

    func revertRule(ruleID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await guarded { try await base.revertRule(ruleID: ruleID, key: key) }
    }

    func removeRule(ruleID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await guarded { try await base.removeRule(ruleID: ruleID, key: key) }
    }

    func rerunCheck(checkID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await guarded { try await base.rerunCheck(checkID: checkID, key: key) }
    }

    func overrideCheck(checkID: UUID, _ request: OverrideCheckRequest, key: IdempotencyKey) async throws
        -> PlainOutcome {
        try await guarded { try await base.overrideCheck(checkID: checkID, request, key: key) }
    }

    func draftContract(taskID: UUID, key: IdempotencyKey) async throws -> CommandOutcome<DraftContractResult> {
        try await guarded { try await base.draftContract(taskID: taskID, key: key) }
    }

    // The Questions and approvals milestone's calls.

    func listDecisions() async throws -> DecisionsList {
        try await guarded { try await base.listDecisions() }
    }

    func listProjects() async throws -> ProjectsList {
        try await guarded { try await base.listProjects() }
    }

    func createProject(_ request: CreateProjectRequest, key: IdempotencyKey) async throws -> PlainOutcome {
        try await guarded { try await base.createProject(request, key: key) }
    }

    func editBrief(projectID: UUID, _ request: EditBriefRequest, key: IdempotencyKey) async throws -> PlainOutcome {
        try await guarded { try await base.editBrief(projectID: projectID, request, key: key) }
    }

    func pauseProject(projectID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await guarded { try await base.pauseProject(projectID: projectID, key: key) }
    }

    func resumeProject(projectID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await guarded { try await base.resumeProject(projectID: projectID, key: key) }
    }

    func deleteProjectContent(projectID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await guarded { try await base.deleteProjectContent(projectID: projectID, key: key) }
    }

    func changeBudget(projectID: UUID, _ request: ChangeBudgetRequest, key: IdempotencyKey) async throws
        -> PlainOutcome {
        try await guarded { try await base.changeBudget(projectID: projectID, request, key: key) }
    }

    func changeTaskPriority(taskID: UUID, _ request: ChangeTaskPriorityRequest, key: IdempotencyKey) async throws
        -> PlainOutcome {
        try await guarded { try await base.changeTaskPriority(taskID: taskID, request, key: key) }
    }

    func changeTaskProject(taskID: UUID, _ request: ChangeTaskProjectRequest, key: IdempotencyKey) async throws
        -> PlainOutcome {
        try await guarded { try await base.changeTaskProject(taskID: taskID, request, key: key) }
    }

    func changeTaskCap(taskID: UUID, _ request: ChangeTaskCapRequest, key: IdempotencyKey) async throws
        -> PlainOutcome {
        try await guarded { try await base.changeTaskCap(taskID: taskID, request, key: key) }
    }

    func returnForRework(taskID: UUID, _ request: ReturnForReworkRequest, key: IdempotencyKey) async throws
        -> PlainOutcome {
        try await guarded { try await base.returnForRework(taskID: taskID, request, key: key) }
    }

    func offerTaskAgain(taskID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await guarded { try await base.offerTaskAgain(taskID: taskID, key: key) }
    }

    func grantAccess(taskID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await guarded { try await base.grantAccess(taskID: taskID, key: key) }
    }

    func deleteTaskContent(taskID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await guarded { try await base.deleteTaskContent(taskID: taskID, key: key) }
    }

    func answerQuestion(questionID: UUID, _ request: AnswerQuestionRequest, key: IdempotencyKey) async throws
        -> PlainOutcome {
        try await guarded { try await base.answerQuestion(questionID: questionID, request, key: key) }
    }

    func overturnAnswer(questionID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await guarded { try await base.overturnAnswer(questionID: questionID, key: key) }
    }

    func approveAction(actionID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await guarded { try await base.approveAction(actionID: actionID, key: key) }
    }

    func stopAction(actionID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await guarded { try await base.stopAction(actionID: actionID, key: key) }
    }

    func waiveAction(actionID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await guarded { try await base.waiveAction(actionID: actionID, key: key) }
    }

    func markActionDone(actionID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await guarded { try await base.markActionDone(actionID: actionID, key: key) }
    }

    func overturnApproval(actionID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await guarded { try await base.overturnApproval(actionID: actionID, key: key) }
    }

    func changeWorkspaceSettings(_ request: ChangeWorkspaceSettingsRequest, key: IdempotencyKey) async throws
        -> CommandOutcome<WorkspaceSettings> {
        try await guarded { try await base.changeWorkspaceSettings(request, key: key) }
    }

    func workspaceSettings() async throws -> WorkspaceSettings {
        try await guarded { try await base.workspaceSettings() }
    }

    func issueLandingPrompt(seatID: UUID, connection: LandingPromptConnection, key: IdempotencyKey)
        async throws -> CommandOutcome<LandingPromptIssuedAnswer> {
        try await guarded { try await base.issueLandingPrompt(seatID: seatID, connection: connection, key: key) }
    }

    // The Credentials milestone's calls.

    func renameCredential(credentialID: UUID, _ request: RenameCredentialRequest, key: IdempotencyKey) async throws
        -> PlainOutcome {
        try await guarded { try await base.renameCredential(credentialID: credentialID, request, key: key) }
    }

    func removeCredential(credentialID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await guarded { try await base.removeCredential(credentialID: credentialID, key: key) }
    }

    func refreshUsage(key: IdempotencyKey) async throws -> CommandOutcome<QueuedRequests> {
        try await guarded { try await base.refreshUsage(key: key) }
    }

    func verifyAllCredentials(key: IdempotencyKey) async throws -> CommandOutcome<QueuedRequests> {
        try await guarded { try await base.verifyAllCredentials(key: key) }
    }

    func reorderCredentials(_ request: ReorderCredentialsRequest, key: IdempotencyKey) async throws -> PlainOutcome {
        try await guarded { try await base.reorderCredentials(request, key: key) }
    }
}

/// The helper's token comes from `issue_helper_token`: this hands any
/// `OwnerAPI` to the helper supervisor as its issuer.
struct OwnerHelperTokenIssuer: HelperTokenIssuing {
    let owner: any OwnerAPI

    func issueHelperToken(name: String, idempotencyKey: String) async throws -> String? {
        try await owner.issueHelperToken(name: name, idempotencyKey: idempotencyKey)
    }
}
