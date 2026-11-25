import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// `OwnerAPI` over HTTP, with the owner's session token. Setup and sign-in
/// send no token.
public struct OwnerClient: OwnerAPI, HelperTokenIssuing {
    public let transport: HTTPTransport

    public init(transport: HTTPTransport) {
        self.transport = transport
    }

    public init(baseURL: URL, sessionToken: String?, session: URLSession = HTTPTransport.uncachedSession) {
        transport = HTTPTransport(baseURL: baseURL, token: sessionToken, session: session)
    }

    /// The same client signed in with `sessionToken`.
    public func signedIn(sessionToken: String?) -> OwnerClient {
        OwnerClient(transport: transport.withToken(sessionToken))
    }

    public func setupState() async throws -> SetupState {
        try await transport.read(.getSetupState, signedIn: false)
    }

    public func createOwner(_ request: SignInRequest, key: IdempotencyKey) async throws
        -> CommandOutcome<OwnerSessionAnswer> {
        try await transport.command(.createOwner, body: request, key: key, signedIn: false)
    }

    public func signIn(_ request: SignInRequest, key: IdempotencyKey) async throws
        -> CommandOutcome<OwnerSessionAnswer> {
        try await transport.command(.signInOwner, body: request, key: key, signedIn: false)
    }

    public func signOut(key: IdempotencyKey) async throws -> PlainOutcome {
        try await transport.command(.signOutOwner, key: key)
    }

    public func ownerIdentity() async throws -> OwnerSessionIdentity {
        try await transport.read(.getOwnerIdentity)
    }

    public func command(key: IdempotencyKey) async throws -> PlainOutcome {
        try await transport.read(.getOwnerCommand, path: ["key": key.value])
    }

    public func events(afterSeq: Int, limit: Int?, wait: Int?) async throws -> EventsPage {
        var query = [URLQueryItem(name: "after_seq", value: String(afterSeq))]
        if let limit { query.append(URLQueryItem(name: "limit", value: String(limit))) }
        return try await transport.read(.listEvents, query: query, waitSeconds: wait)
    }

    public func board() async throws -> Board {
        try await transport.read(.getBoard)
    }

    public func task(id: UUID) async throws -> TaskPage {
        try await transport.read(.getTask, path: ["id": id.contractString])
    }

    public func seats() async throws -> SeatsList {
        try await transport.read(.listSeats)
    }

    public func credentials() async throws -> CredentialsList {
        try await transport.read(.listCredentials)
    }

    public func systemHealth() async throws -> SystemHealth {
        try await transport.read(.getSystemHealth)
    }

    public func helperRequest(id: UUID, wait: Int?, changedAfter: Date?) async throws -> HelperRequestStatus {
        var query: [URLQueryItem] = []
        if let changedAfter {
            query.append(URLQueryItem(name: "changed_after", value: LeverageJSON.string(from: changedAfter)))
        }
        return try await transport.read(
            .getHelperRequest, path: ["id": id.contractString], query: query, waitSeconds: wait)
    }

    public func addTask(_ request: AddTaskRequest, key: IdempotencyKey) async throws
        -> CommandOutcome<TaskCreatedResult> {
        try await transport.command(.addTask, body: request, key: key)
    }

    public func completeContract(taskID: UUID, _ request: CompleteContractRequest, key: IdempotencyKey)
        async throws -> PlainOutcome {
        try await transport.command(.completeContract, path: ["id": taskID.contractString], body: request, key: key)
    }

    public func cancelTask(taskID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await transport.command(.cancelTask, path: ["id": taskID.contractString], key: key)
    }

    public func allowAnotherRound(taskID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await transport.command(.allowAnotherRound, path: ["id": taskID.contractString], key: key)
    }

    public func connectSeat(_ request: ConnectSeatRequest, key: IdempotencyKey) async throws
        -> CommandOutcome<SeatConnected> {
        try await transport.command(.connectSeat, body: request, key: key)
    }

    public func issueLandingPrompt(seatID: UUID, connection: LandingPromptConnection, key: IdempotencyKey)
        async throws -> CommandOutcome<LandingPromptIssuedAnswer> {
        try await transport.command(
            .issueLandingPrompt, path: ["id": seatID.contractString],
            body: IssueLandingPromptRequest(connection: connection), key: key)
    }

    public func startSeat(seatID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await transport.command(.startSeat, path: ["id": seatID.contractString], key: key)
    }

    public func stopSeat(seatID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await transport.command(.stopSeat, path: ["id": seatID.contractString], key: key)
    }

    public func removeSeat(seatID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await transport.command(.removeSeat, path: ["id": seatID.contractString], key: key)
    }

    public func issueHelperToken(name: String, key: IdempotencyKey) async throws -> CommandOutcome<HelperTokenAnswer> {
        try await transport.command(.issueHelperToken, body: IssueHelperTokenRequest(name: name), key: key)
    }

    public func addCredential(_ request: AddCredentialRequest, key: IdempotencyKey) async throws
        -> CommandOutcome<AddCredentialResult> {
        try await transport.command(.addCredential, body: request, key: key)
    }

    public func verifyCredential(credentialID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await transport.command(.verifyCredential, path: ["id": credentialID.contractString], key: key)
    }

    public func renameCredential(credentialID: UUID, _ request: RenameCredentialRequest, key: IdempotencyKey)
        async throws -> PlainOutcome {
        try await transport.command(
            .renameCredential, path: ["id": credentialID.contractString], body: request, key: key)
    }

    public func removeCredential(credentialID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await transport.command(.removeCredential, path: ["id": credentialID.contractString], key: key)
    }

    public func refreshUsage(key: IdempotencyKey) async throws -> CommandOutcome<QueuedRequests> {
        try await transport.command(.refreshUsage, key: key)
    }

    public func verifyAllCredentials(key: IdempotencyKey) async throws -> CommandOutcome<QueuedRequests> {
        try await transport.command(.verifyAllCredentials, key: key)
    }

    public func reorderCredentials(_ request: ReorderCredentialsRequest, key: IdempotencyKey) async throws
        -> PlainOutcome {
        try await transport.command(.reorderCredentials, body: request, key: key)
    }

    public func installTool(provider: Provider, key: IdempotencyKey) async throws -> PlainOutcome {
        try await transport.command(
            .installTool, path: ["provider": provider.rawValue], body: InstallToolRequest(), key: key)
    }

    public func listInbox(afterSeq: Int?, wait: Int?) async throws -> InboxPage {
        var query: [URLQueryItem] = []
        if let afterSeq { query.append(URLQueryItem(name: "after_seq", value: String(afterSeq))) }
        return try await transport.read(.listInbox, query: query, waitSeconds: wait)
    }

    public func promoteTask(taskID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await transport.command(.promoteTask, path: ["id": taskID.contractString], key: key)
    }

    public func editContract(taskID: UUID, _ request: CompleteContractRequest, key: IdempotencyKey) async throws
        -> PlainOutcome {
        try await transport.command(.editContract, path: ["id": taskID.contractString], body: request, key: key)
    }

    public func holdTask(taskID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await transport.command(.holdTask, path: ["id": taskID.contractString], key: key)
    }

    public func resumeTask(taskID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await transport.command(.resumeTask, path: ["id": taskID.contractString], key: key)
    }

    public func pauseSeat(seatID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await transport.command(.pauseSeat, path: ["id": seatID.contractString], key: key)
    }

    public func resumeSeat(seatID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await transport.command(.resumeSeat, path: ["id": seatID.contractString], key: key)
    }

    public func changeSeat(seatID: UUID, _ request: ChangeSeatRequest, key: IdempotencyKey) async throws
        -> PlainOutcome {
        try await transport.command(.changeSeat, path: ["id": seatID.contractString], body: request, key: key)
    }

    public func signInAgain(credentialID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await transport.command(.signInAgain, path: ["id": credentialID.contractString], key: key)
    }

    public func listRules() async throws -> RulesList {
        try await transport.read(.listRules)
    }

    public func addRule(_ request: AddRuleRequest, key: IdempotencyKey) async throws -> PlainOutcome {
        try await transport.command(.addRule, body: request, key: key)
    }

    public func saveRule(ruleID: UUID, _ request: SaveRuleRequest, key: IdempotencyKey) async throws
        -> PlainOutcome {
        try await transport.command(.saveRule, path: ["id": ruleID.contractString], body: request, key: key)
    }

    public func enableRule(ruleID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await transport.command(.enableRule, path: ["id": ruleID.contractString], key: key)
    }

    public func disableRule(ruleID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await transport.command(.disableRule, path: ["id": ruleID.contractString], key: key)
    }

    public func revertRule(ruleID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await transport.command(.revertRule, path: ["id": ruleID.contractString], key: key)
    }

    public func removeRule(ruleID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await transport.command(.removeRule, path: ["id": ruleID.contractString], key: key)
    }

    public func rerunCheck(checkID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await transport.command(.rerunCheck, path: ["id": checkID.contractString], key: key)
    }

    public func overrideCheck(checkID: UUID, _ request: OverrideCheckRequest, key: IdempotencyKey) async throws
        -> PlainOutcome {
        try await transport.command(.overrideCheck, path: ["id": checkID.contractString], body: request, key: key)
    }

    public func draftContract(taskID: UUID, key: IdempotencyKey) async throws
        -> CommandOutcome<DraftContractResult> {
        try await transport.command(.draftContract, path: ["id": taskID.contractString], key: key)
    }
}


extension OwnerClient {
    public func listDecisions() async throws -> DecisionsList {
        try await transport.read(.listDecisions)
    }

    public func listProjects() async throws -> ProjectsList {
        try await transport.read(.listProjects)
    }

    public func createProject(_ request: CreateProjectRequest, key: IdempotencyKey) async throws -> PlainOutcome {
        try await transport.command(.createProject, body: request, key: key)
    }

    public func editBrief(projectID: UUID, _ request: EditBriefRequest, key: IdempotencyKey) async throws
        -> PlainOutcome {
        try await transport.command(.editBrief, path: ["id": projectID.contractString], body: request, key: key)
    }

    public func pauseProject(projectID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await transport.command(.pauseProject, path: ["id": projectID.contractString], key: key)
    }

    public func resumeProject(projectID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await transport.command(.resumeProject, path: ["id": projectID.contractString], key: key)
    }

    public func deleteProjectContent(projectID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await transport.command(.deleteProjectContent, path: ["id": projectID.contractString], key: key)
    }

    public func changeBudget(projectID: UUID, _ request: ChangeBudgetRequest, key: IdempotencyKey) async throws
        -> PlainOutcome {
        try await transport.command(.changeBudget, path: ["id": projectID.contractString], body: request, key: key)
    }

    public func changeTaskPriority(taskID: UUID, _ request: ChangeTaskPriorityRequest, key: IdempotencyKey) async throws
        -> PlainOutcome {
        try await transport.command(
            .changeTaskPriority, path: ["id": taskID.contractString],
            body: request, key: key)
    }

    public func changeTaskProject(taskID: UUID, _ request: ChangeTaskProjectRequest, key: IdempotencyKey) async throws
        -> PlainOutcome {
        try await transport.command(
            .changeTaskProject, path: ["id": taskID.contractString],
            body: request, key: key)
    }

    public func changeTaskCap(taskID: UUID, _ request: ChangeTaskCapRequest, key: IdempotencyKey) async throws
        -> PlainOutcome {
        try await transport.command(.changeTaskCap, path: ["id": taskID.contractString], body: request, key: key)
    }

    public func returnForRework(taskID: UUID, _ request: ReturnForReworkRequest, key: IdempotencyKey) async throws
        -> PlainOutcome {
        try await transport.command(.returnForRework, path: ["id": taskID.contractString], body: request, key: key)
    }

    public func offerTaskAgain(taskID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await transport.command(.offerTaskAgain, path: ["id": taskID.contractString], key: key)
    }

    public func grantAccess(taskID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await transport.command(.grantAccess, path: ["id": taskID.contractString], key: key)
    }

    public func deleteTaskContent(taskID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await transport.command(.deleteTaskContent, path: ["id": taskID.contractString], key: key)
    }

    public func answerQuestion(questionID: UUID, _ request: AnswerQuestionRequest, key: IdempotencyKey) async throws
        -> PlainOutcome {
        try await transport.command(
            .answerQuestion, path: ["id": questionID.contractString],
            body: request, key: key)
    }

    public func overturnAnswer(questionID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await transport.command(.overturnAnswer, path: ["id": questionID.contractString], key: key)
    }

    public func approveAction(actionID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await transport.command(.approveAction, path: ["id": actionID.contractString], key: key)
    }

    public func stopAction(actionID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await transport.command(.stopAction, path: ["id": actionID.contractString], key: key)
    }

    public func waiveAction(actionID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await transport.command(.waiveAction, path: ["id": actionID.contractString], key: key)
    }

    public func markActionDone(actionID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await transport.command(.markActionDone, path: ["id": actionID.contractString], key: key)
    }

    public func overturnApproval(actionID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await transport.command(.overturnApproval, path: ["id": actionID.contractString], key: key)
    }

    public func changeWorkspaceSettings(_ request: ChangeWorkspaceSettingsRequest, key: IdempotencyKey) async throws
        -> CommandOutcome<WorkspaceSettings> {
        try await transport.command(.changeWorkspaceSettings, body: request, key: key)
    }

    public func workspaceSettings() async throws -> WorkspaceSettings {
        try await transport.read(.getWorkspaceSettings)
    }
}

package struct IssueLandingPromptRequest: Encodable, Sendable {
    package let connection: LandingPromptConnection

    package init(connection: LandingPromptConnection) {
        self.connection = connection
    }
}
