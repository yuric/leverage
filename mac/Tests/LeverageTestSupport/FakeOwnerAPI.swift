import Foundation
import LeverageKit

/// One call a fake API was asked to make: the operation, its path
/// parameters as the HTTP client would fill them, its query, key, and body as
/// JSON (what the HTTP client would send).
public struct FakeCall: Equatable, Sendable {
    public let operation: ContractOperation
    public let path: [String: String]
    public let query: [String: String]
    public let key: IdempotencyKey?
    public let body: JSONValue?

    public init(
        _ operation: ContractOperation, path: [String: String] = [:], key: IdempotencyKey? = nil,
        body: JSONValue? = nil, query: [String: String] = [:]
    ) {
        self.operation = operation
        self.path = path
        self.query = query
        self.key = key
        self.body = body
    }

    /// The body as the HTTP client would encode it.
    public static func json(_ body: some Encodable) -> JSONValue? {
        guard let data = try? LeverageJSON.encoder().encode(body) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }
}

/// What a fake answers when the test has not said: every call throws it.
public enum FakeAPIError: Error, Equatable, Sendable {
    case notScripted(ContractOperation)
}

/// The calls a fake recorded, and the answers a test scripted, behind one
/// lock.
final class FakeState<Answers: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var answers: Answers
    private var calls: [FakeCall] = []

    init(_ answers: Answers) { self.answers = answers }

    func record(_ call: FakeCall) -> Answers {
        lock.withLock {
            calls.append(call)
            return answers
        }
    }

    func script(_ change: (inout Answers) -> Void) { lock.withLock { change(&answers) } }
    var recorded: [FakeCall] { lock.withLock { calls } }
    func forget() { lock.withLock { calls.removeAll() } }
}

/// An in-memory `OwnerAPI` for the app's view model tests. The test
/// scripts the answers it needs (`script { $0.board = { ... } }`); every
/// other call throws `FakeAPIError.notScripted`. Every call is recorded,
/// in order, in `calls`.
public final class FakeOwnerAPI: OwnerAPI, HelperTokenIssuing, @unchecked Sendable {
    public typealias Command<Request, Result: Sendable> = @Sendable (Request, IdempotencyKey) async throws
        -> CommandOutcome<Result>
    public typealias IDCommand = @Sendable (UUID, IdempotencyKey) async throws -> PlainOutcome

    public struct Answers: Sendable {
        public var setupState: @Sendable () async throws -> SetupState = { throw FakeAPIError.notScripted(.getSetupState) }
        public var createOwner: Command<SignInRequest, OwnerSessionAnswer> = { _, _ in
            throw FakeAPIError.notScripted(.createOwner)
        }
        public var signIn: Command<SignInRequest, OwnerSessionAnswer> = { _, _ in
            throw FakeAPIError.notScripted(.signInOwner)
        }
        public var signOut: @Sendable (IdempotencyKey) async throws -> PlainOutcome = { _ in
            throw FakeAPIError.notScripted(.signOutOwner)
        }
        public var command: @Sendable (IdempotencyKey) async throws -> PlainOutcome = { _ in
            throw FakeAPIError.notScripted(.getOwnerCommand)
        }
        public var events: @Sendable (Int, Int?, Int?) async throws -> EventsPage = { _, _, _ in
            throw FakeAPIError.notScripted(.listEvents)
        }
        public var board: @Sendable () async throws -> Board = { throw FakeAPIError.notScripted(.getBoard) }
        public var task: @Sendable (UUID) async throws -> TaskPage = { _ in throw FakeAPIError.notScripted(.getTask) }
        public var seats: @Sendable () async throws -> SeatsList = { throw FakeAPIError.notScripted(.listSeats) }
        public var credentials: @Sendable () async throws -> CredentialsList = {
            throw FakeAPIError.notScripted(.listCredentials)
        }
        public var systemHealth: @Sendable () async throws -> SystemHealth = {
            throw FakeAPIError.notScripted(.getSystemHealth)
        }
        public var helperRequest: @Sendable (UUID, Int?, Date?) async throws -> HelperRequestStatus = { _, _, _ in
            throw FakeAPIError.notScripted(.getHelperRequest)
        }
        public var landingPrompt: @Sendable (UUID) async throws -> LandingPrompt = { _ in
            throw FakeAPIError.notScripted(.getLandingPrompt)
        }
        public var listInbox: @Sendable (Int?, Int?) async throws -> InboxPage = { _, _ in
            throw FakeAPIError.notScripted(.listInbox)
        }
        public var addTask: Command<AddTaskRequest, TaskCreatedResult> = { _, _ in
            throw FakeAPIError.notScripted(.addTask)
        }
        public var completeContract: @Sendable (UUID, CompleteContractRequest, IdempotencyKey) async throws
            -> PlainOutcome = { _, _, _ in throw FakeAPIError.notScripted(.completeContract) }
        public var cancelTask: IDCommand = { _, _ in throw FakeAPIError.notScripted(.cancelTask) }
        public var allowAnotherRound: IDCommand = { _, _ in throw FakeAPIError.notScripted(.allowAnotherRound) }
        public var promoteTask: IDCommand = { _, _ in throw FakeAPIError.notScripted(.promoteTask) }
        public var editContract: @Sendable (UUID, CompleteContractRequest, IdempotencyKey) async throws
            -> PlainOutcome = { _, _, _ in throw FakeAPIError.notScripted(.editContract) }
        public var holdTask: IDCommand = { _, _ in throw FakeAPIError.notScripted(.holdTask) }
        public var resumeTask: IDCommand = { _, _ in throw FakeAPIError.notScripted(.resumeTask) }
        public var connectSeat: Command<ConnectSeatRequest, SeatConnectedAnswer> = { _, _ in
            throw FakeAPIError.notScripted(.connectSeat)
        }
        public var startSeat: IDCommand = { _, _ in throw FakeAPIError.notScripted(.startSeat) }
        public var stopSeat: IDCommand = { _, _ in throw FakeAPIError.notScripted(.stopSeat) }
        public var removeSeat: IDCommand = { _, _ in throw FakeAPIError.notScripted(.removeSeat) }
        public var pauseSeat: IDCommand = { _, _ in throw FakeAPIError.notScripted(.pauseSeat) }
        public var resumeSeat: IDCommand = { _, _ in throw FakeAPIError.notScripted(.resumeSeat) }
        public var changeSeat: @Sendable (UUID, ChangeSeatRequest, IdempotencyKey) async throws
            -> PlainOutcome = { _, _, _ in throw FakeAPIError.notScripted(.changeSeat) }
        public var issueHelperToken: Command<String, HelperTokenAnswer> = { _, _ in
            throw FakeAPIError.notScripted(.issueHelperToken)
        }
        public var addCredential: Command<AddCredentialRequest, AddCredentialResult> = { _, _ in
            throw FakeAPIError.notScripted(.addCredential)
        }
        public var verifyCredential: IDCommand = { _, _ in throw FakeAPIError.notScripted(.verifyCredential) }
        public var signInAgain: IDCommand = { _, _ in throw FakeAPIError.notScripted(.signInAgain) }
        public var installTool: @Sendable (Provider, IdempotencyKey) async throws -> PlainOutcome = { _, _ in
            throw FakeAPIError.notScripted(.installTool)
        }
        public var listRules: @Sendable () async throws -> RulesList = { throw FakeAPIError.notScripted(.listRules) }
        public var addRule: @Sendable (AddRuleRequest, IdempotencyKey) async throws -> PlainOutcome = { _, _ in
            throw FakeAPIError.notScripted(.addRule)
        }
        public var saveRule: @Sendable (UUID, SaveRuleRequest, IdempotencyKey) async throws -> PlainOutcome = {
            _, _, _ in throw FakeAPIError.notScripted(.saveRule)
        }
        public var enableRule: IDCommand = { _, _ in throw FakeAPIError.notScripted(.enableRule) }
        public var disableRule: IDCommand = { _, _ in throw FakeAPIError.notScripted(.disableRule) }
        public var revertRule: IDCommand = { _, _ in throw FakeAPIError.notScripted(.revertRule) }
        public var removeRule: IDCommand = { _, _ in throw FakeAPIError.notScripted(.removeRule) }
        public var rerunCheck: IDCommand = { _, _ in throw FakeAPIError.notScripted(.rerunCheck) }
        public var overrideCheck: @Sendable (UUID, OverrideCheckRequest, IdempotencyKey) async throws
            -> PlainOutcome = { _, _, _ in throw FakeAPIError.notScripted(.overrideCheck) }
        public var draftContract: @Sendable (UUID, IdempotencyKey) async throws
            -> CommandOutcome<DraftContractResult> = { _, _ in throw FakeAPIError.notScripted(.draftContract) }

        public var listDecisions: @Sendable () async throws -> DecisionsList = {
            throw FakeAPIError.notScripted(.listDecisions)
        }
        public var listProjects: @Sendable () async throws -> ProjectsList = {
            throw FakeAPIError.notScripted(.listProjects)
        }
        public var createProject: @Sendable (CreateProjectRequest, IdempotencyKey) async throws -> PlainOutcome = {
            _, _ in throw FakeAPIError.notScripted(.createProject)
        }
        public var editBrief: @Sendable (UUID, EditBriefRequest, IdempotencyKey) async throws -> PlainOutcome = {
            _, _, _ in throw FakeAPIError.notScripted(.editBrief)
        }
        public var pauseProject: @Sendable (UUID, IdempotencyKey) async throws -> PlainOutcome = {
            _, _ in throw FakeAPIError.notScripted(.pauseProject)
        }
        public var resumeProject: @Sendable (UUID, IdempotencyKey) async throws -> PlainOutcome = {
            _, _ in throw FakeAPIError.notScripted(.resumeProject)
        }
        public var deleteProjectContent: @Sendable (UUID, IdempotencyKey) async throws -> PlainOutcome = {
            _, _ in throw FakeAPIError.notScripted(.deleteProjectContent)
        }
        public var changeBudget: @Sendable (UUID, ChangeBudgetRequest, IdempotencyKey) async throws -> PlainOutcome = {
            _, _, _ in throw FakeAPIError.notScripted(.changeBudget)
        }
        public var changeTaskPriority: @Sendable (UUID, ChangeTaskPriorityRequest, IdempotencyKey) async throws -> PlainOutcome = {
            _, _, _ in throw FakeAPIError.notScripted(.changeTaskPriority)
        }
        public var changeTaskProject: @Sendable (UUID, ChangeTaskProjectRequest, IdempotencyKey) async throws -> PlainOutcome = {
            _, _, _ in throw FakeAPIError.notScripted(.changeTaskProject)
        }
        public var changeTaskCap: @Sendable (UUID, ChangeTaskCapRequest, IdempotencyKey) async throws -> PlainOutcome = {
            _, _, _ in throw FakeAPIError.notScripted(.changeTaskCap)
        }
        public var returnForRework: @Sendable (UUID, ReturnForReworkRequest, IdempotencyKey) async throws -> PlainOutcome = {
            _, _, _ in throw FakeAPIError.notScripted(.returnForRework)
        }
        public var offerTaskAgain: @Sendable (UUID, IdempotencyKey) async throws -> PlainOutcome = {
            _, _ in throw FakeAPIError.notScripted(.offerTaskAgain)
        }
        public var grantAccess: @Sendable (UUID, IdempotencyKey) async throws -> PlainOutcome = {
            _, _ in throw FakeAPIError.notScripted(.grantAccess)
        }
        public var deleteTaskContent: @Sendable (UUID, IdempotencyKey) async throws -> PlainOutcome = {
            _, _ in throw FakeAPIError.notScripted(.deleteTaskContent)
        }
        public var answerQuestion: @Sendable (UUID, AnswerQuestionRequest, IdempotencyKey) async throws -> PlainOutcome = {
            _, _, _ in throw FakeAPIError.notScripted(.answerQuestion)
        }
        public var overturnAnswer: @Sendable (UUID, IdempotencyKey) async throws -> PlainOutcome = {
            _, _ in throw FakeAPIError.notScripted(.overturnAnswer)
        }
        public var approveAction: @Sendable (UUID, IdempotencyKey) async throws -> PlainOutcome = {
            _, _ in throw FakeAPIError.notScripted(.approveAction)
        }
        public var stopAction: @Sendable (UUID, IdempotencyKey) async throws -> PlainOutcome = {
            _, _ in throw FakeAPIError.notScripted(.stopAction)
        }
        public var waiveAction: @Sendable (UUID, IdempotencyKey) async throws -> PlainOutcome = {
            _, _ in throw FakeAPIError.notScripted(.waiveAction)
        }
        public var markActionDone: @Sendable (UUID, IdempotencyKey) async throws -> PlainOutcome = {
            _, _ in throw FakeAPIError.notScripted(.markActionDone)
        }
        public var overturnApproval: @Sendable (UUID, IdempotencyKey) async throws -> PlainOutcome = {
            _, _ in throw FakeAPIError.notScripted(.overturnApproval)
        }
        public var changeWorkspaceSettings: @Sendable (ChangeWorkspaceSettingsRequest, IdempotencyKey) async throws -> CommandOutcome<WorkspaceSettings> = {
            _, _ in throw FakeAPIError.notScripted(.changeWorkspaceSettings)
        }
        public var workspaceSettings: @Sendable () async throws -> WorkspaceSettings = {
            throw FakeAPIError.notScripted(.getWorkspaceSettings)
        }
        public var landingPromptForConnection: (@Sendable (UUID, LandingPromptConnection) async throws -> LandingPrompt)?

        public init() {}
    }

    private let state = FakeState(Answers())

    public init() {}

    /// Changes the scripted answers.
    public func script(_ change: (inout Answers) -> Void) { state.script(change) }
    /// Every call made so far, in order.
    public var calls: [FakeCall] { state.recorded }
    public func forgetCalls() { state.forget() }

    private func record(
        _ operation: ContractOperation, _ path: [String: String] = [:], key: IdempotencyKey? = nil,
        body: (any Encodable)? = nil, query: [String: String] = [:]
    ) -> Answers {
        state.record(FakeCall(operation, path: path, key: key, body: body.flatMap { FakeCall.json($0) }, query: query))
    }

    private static func id(_ uuid: UUID) -> [String: String] { ["id": uuid.contractString] }

    public func setupState() async throws -> SetupState {
        try await record(.getSetupState).setupState()
    }

    public func createOwner(_ request: SignInRequest, key: IdempotencyKey) async throws
        -> CommandOutcome<OwnerSessionAnswer> {
        try await record(.createOwner, key: key, body: request).createOwner(request, key)
    }

    public func signIn(_ request: SignInRequest, key: IdempotencyKey) async throws
        -> CommandOutcome<OwnerSessionAnswer> {
        try await record(.signInOwner, key: key, body: request).signIn(request, key)
    }

    public func signOut(key: IdempotencyKey) async throws -> PlainOutcome {
        try await record(.signOutOwner, key: key).signOut(key)
    }

    public func command(key: IdempotencyKey) async throws -> PlainOutcome {
        try await record(.getOwnerCommand, ["key": key.value]).command(key)
    }

    public func events(afterSeq: Int, limit: Int?, wait: Int?) async throws -> EventsPage {
        try await record(.listEvents).events(afterSeq, limit, wait)
    }

    public func board() async throws -> Board {
        try await record(.getBoard).board()
    }

    public func task(id: UUID) async throws -> TaskPage {
        try await record(.getTask, Self.id(id)).task(id)
    }

    public func seats() async throws -> SeatsList {
        try await record(.listSeats).seats()
    }

    public func credentials() async throws -> CredentialsList {
        try await record(.listCredentials).credentials()
    }

    public func systemHealth() async throws -> SystemHealth {
        try await record(.getSystemHealth).systemHealth()
    }

    public func helperRequest(id: UUID, wait: Int?, changedAfter: Date?) async throws -> HelperRequestStatus {
        try await record(.getHelperRequest, Self.id(id)).helperRequest(id, wait, changedAfter)
    }

    public func landingPrompt(seatID: UUID) async throws -> LandingPrompt {
        try await record(.getLandingPrompt, Self.id(seatID)).landingPrompt(seatID)
    }

    public func listInbox(afterSeq: Int?, wait: Int?) async throws -> InboxPage {
        try await record(.listInbox).listInbox(afterSeq, wait)
    }

    public func addTask(_ request: AddTaskRequest, key: IdempotencyKey) async throws
        -> CommandOutcome<TaskCreatedResult> {
        try await record(.addTask, key: key, body: request).addTask(request, key)
    }

    public func completeContract(taskID: UUID, _ request: CompleteContractRequest, key: IdempotencyKey)
        async throws -> PlainOutcome {
        try await record(.completeContract, Self.id(taskID), key: key, body: request)
            .completeContract(taskID, request, key)
    }

    public func cancelTask(taskID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await record(.cancelTask, Self.id(taskID), key: key).cancelTask(taskID, key)
    }

    public func allowAnotherRound(taskID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await record(.allowAnotherRound, Self.id(taskID), key: key).allowAnotherRound(taskID, key)
    }

    public func promoteTask(taskID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await record(.promoteTask, Self.id(taskID), key: key).promoteTask(taskID, key)
    }

    public func editContract(taskID: UUID, _ request: CompleteContractRequest, key: IdempotencyKey)
        async throws -> PlainOutcome {
        try await record(.editContract, Self.id(taskID), key: key, body: request)
            .editContract(taskID, request, key)
    }

    public func holdTask(taskID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await record(.holdTask, Self.id(taskID), key: key).holdTask(taskID, key)
    }

    public func resumeTask(taskID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await record(.resumeTask, Self.id(taskID), key: key).resumeTask(taskID, key)
    }

    public func connectSeat(_ request: ConnectSeatRequest, key: IdempotencyKey) async throws
        -> CommandOutcome<SeatConnectedAnswer> {
        try await record(.connectSeat, key: key, body: request).connectSeat(request, key)
    }

    public func startSeat(seatID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await record(.startSeat, Self.id(seatID), key: key).startSeat(seatID, key)
    }

    public func stopSeat(seatID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await record(.stopSeat, Self.id(seatID), key: key).stopSeat(seatID, key)
    }

    public func removeSeat(seatID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await record(.removeSeat, Self.id(seatID), key: key).removeSeat(seatID, key)
    }

    public func pauseSeat(seatID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await record(.pauseSeat, Self.id(seatID), key: key).pauseSeat(seatID, key)
    }

    public func resumeSeat(seatID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await record(.resumeSeat, Self.id(seatID), key: key).resumeSeat(seatID, key)
    }

    public func changeSeat(seatID: UUID, _ request: ChangeSeatRequest, key: IdempotencyKey) async throws
        -> PlainOutcome {
        try await record(.changeSeat, Self.id(seatID), key: key, body: request).changeSeat(seatID, request, key)
    }

    public func issueHelperToken(name: String, key: IdempotencyKey) async throws -> CommandOutcome<HelperTokenAnswer> {
        try await record(.issueHelperToken, key: key, body: IssueHelperTokenRequest(name: name))
            .issueHelperToken(name, key)
    }

    public func addCredential(_ request: AddCredentialRequest, key: IdempotencyKey) async throws
        -> CommandOutcome<AddCredentialResult> {
        try await record(.addCredential, key: key, body: request).addCredential(request, key)
    }

    public func verifyCredential(credentialID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await record(.verifyCredential, Self.id(credentialID), key: key).verifyCredential(credentialID, key)
    }

    public func renameCredential(credentialID: UUID, _ request: RenameCredentialRequest, key: IdempotencyKey)
        async throws -> PlainOutcome {
        throw FakeAPIError.notScripted(.renameCredential)
    }

    public func removeCredential(credentialID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        throw FakeAPIError.notScripted(.removeCredential)
    }

    public func refreshUsage(key: IdempotencyKey) async throws -> CommandOutcome<QueuedRequests> {
        throw FakeAPIError.notScripted(.refreshUsage)
    }

    public func verifyAllCredentials(key: IdempotencyKey) async throws -> CommandOutcome<QueuedRequests> {
        throw FakeAPIError.notScripted(.verifyAllCredentials)
    }

    public func reorderCredentials(_ request: ReorderCredentialsRequest, key: IdempotencyKey) async throws
        -> PlainOutcome {
        throw FakeAPIError.notScripted(.reorderCredentials)
    }

    public func signInAgain(credentialID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await record(.signInAgain, Self.id(credentialID), key: key).signInAgain(credentialID, key)
    }

    public func installTool(provider: Provider, key: IdempotencyKey) async throws -> PlainOutcome {
        try await record(.installTool, ["provider": provider.rawValue], key: key, body: InstallToolRequest())
            .installTool(provider, key)
    }

    public func listRules() async throws -> RulesList {
        try await record(.listRules).listRules()
    }

    public func addRule(_ request: AddRuleRequest, key: IdempotencyKey) async throws -> PlainOutcome {
        try await record(.addRule, key: key, body: request).addRule(request, key)
    }

    public func saveRule(ruleID: UUID, _ request: SaveRuleRequest, key: IdempotencyKey) async throws
        -> PlainOutcome {
        try await record(.saveRule, Self.id(ruleID), key: key, body: request).saveRule(ruleID, request, key)
    }

    public func enableRule(ruleID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await record(.enableRule, Self.id(ruleID), key: key).enableRule(ruleID, key)
    }

    public func disableRule(ruleID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await record(.disableRule, Self.id(ruleID), key: key).disableRule(ruleID, key)
    }

    public func revertRule(ruleID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await record(.revertRule, Self.id(ruleID), key: key).revertRule(ruleID, key)
    }

    public func removeRule(ruleID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await record(.removeRule, Self.id(ruleID), key: key).removeRule(ruleID, key)
    }

    public func rerunCheck(checkID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await record(.rerunCheck, Self.id(checkID), key: key).rerunCheck(checkID, key)
    }

    public func overrideCheck(checkID: UUID, _ request: OverrideCheckRequest, key: IdempotencyKey) async throws
        -> PlainOutcome {
        try await record(.overrideCheck, Self.id(checkID), key: key, body: request)
            .overrideCheck(checkID, request, key)
    }

    public func draftContract(taskID: UUID, key: IdempotencyKey) async throws
        -> CommandOutcome<DraftContractResult> {
        try await record(.draftContract, Self.id(taskID), key: key).draftContract(taskID, key)
    }

    public func listDecisions() async throws -> DecisionsList {
        try await record(.listDecisions).listDecisions()
    }

    public func listProjects() async throws -> ProjectsList {
        try await record(.listProjects).listProjects()
    }

    public func createProject(_ request: CreateProjectRequest, key: IdempotencyKey) async throws -> PlainOutcome {
        try await record(.createProject, key: key, body: request).createProject(request, key)
    }

    public func editBrief(projectID: UUID, _ request: EditBriefRequest, key: IdempotencyKey) async throws
        -> PlainOutcome {
        try await record(.editBrief, Self.id(projectID), key: key, body: request).editBrief(projectID, request, key)
    }

    public func pauseProject(projectID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await record(.pauseProject, Self.id(projectID), key: key).pauseProject(projectID, key)
    }

    public func resumeProject(projectID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await record(.resumeProject, Self.id(projectID), key: key).resumeProject(projectID, key)
    }

    public func deleteProjectContent(projectID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await record(.deleteProjectContent, Self.id(projectID), key: key).deleteProjectContent(projectID, key)
    }

    public func changeBudget(projectID: UUID, _ request: ChangeBudgetRequest, key: IdempotencyKey) async throws
        -> PlainOutcome {
        try await record(.changeBudget, Self.id(projectID), key: key, body: request)
            .changeBudget(projectID, request, key)
    }

    public func changeTaskPriority(taskID: UUID, _ request: ChangeTaskPriorityRequest, key: IdempotencyKey) async throws
        -> PlainOutcome {
        try await record(.changeTaskPriority, Self.id(taskID), key: key, body: request)
            .changeTaskPriority(taskID, request, key)
    }

    public func changeTaskProject(taskID: UUID, _ request: ChangeTaskProjectRequest, key: IdempotencyKey) async throws
        -> PlainOutcome {
        try await record(.changeTaskProject, Self.id(taskID), key: key, body: request)
            .changeTaskProject(taskID, request, key)
    }

    public func changeTaskCap(taskID: UUID, _ request: ChangeTaskCapRequest, key: IdempotencyKey) async throws
        -> PlainOutcome {
        try await record(.changeTaskCap, Self.id(taskID), key: key, body: request)
            .changeTaskCap(taskID, request, key)
    }

    public func returnForRework(taskID: UUID, _ request: ReturnForReworkRequest, key: IdempotencyKey) async throws
        -> PlainOutcome {
        try await record(.returnForRework, Self.id(taskID), key: key, body: request)
            .returnForRework(taskID, request, key)
    }

    public func offerTaskAgain(taskID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await record(.offerTaskAgain, Self.id(taskID), key: key).offerTaskAgain(taskID, key)
    }

    public func grantAccess(taskID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await record(.grantAccess, Self.id(taskID), key: key).grantAccess(taskID, key)
    }

    public func deleteTaskContent(taskID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await record(.deleteTaskContent, Self.id(taskID), key: key).deleteTaskContent(taskID, key)
    }

    public func answerQuestion(questionID: UUID, _ request: AnswerQuestionRequest, key: IdempotencyKey) async throws
        -> PlainOutcome {
        try await record(.answerQuestion, Self.id(questionID), key: key, body: request)
            .answerQuestion(questionID, request, key)
    }

    public func overturnAnswer(questionID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await record(.overturnAnswer, Self.id(questionID), key: key).overturnAnswer(questionID, key)
    }

    public func approveAction(actionID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await record(.approveAction, Self.id(actionID), key: key).approveAction(actionID, key)
    }

    public func stopAction(actionID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await record(.stopAction, Self.id(actionID), key: key).stopAction(actionID, key)
    }

    public func waiveAction(actionID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await record(.waiveAction, Self.id(actionID), key: key).waiveAction(actionID, key)
    }

    public func markActionDone(actionID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await record(.markActionDone, Self.id(actionID), key: key).markActionDone(actionID, key)
    }

    public func overturnApproval(actionID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await record(.overturnApproval, Self.id(actionID), key: key).overturnApproval(actionID, key)
    }

    public func changeWorkspaceSettings(_ request: ChangeWorkspaceSettingsRequest, key: IdempotencyKey) async throws
        -> CommandOutcome<WorkspaceSettings> {
        try await record(.changeWorkspaceSettings, key: key, body: request).changeWorkspaceSettings(request, key)
    }

    public func workspaceSettings() async throws -> WorkspaceSettings {
        try await record(.getWorkspaceSettings).workspaceSettings()
    }

    public func landingPrompt(seatID: UUID, connection: LandingPromptConnection) async throws -> LandingPrompt {
        let answers = record(.getLandingPrompt, Self.id(seatID), query: ["connection": connection.rawValue])
        if let answer = answers.landingPromptForConnection { return try await answer(seatID, connection) }
        guard connection == .http else { throw FakeAPIError.notScripted(.getLandingPrompt) }
        return try await answers.landingPrompt(seatID)
    }
}
