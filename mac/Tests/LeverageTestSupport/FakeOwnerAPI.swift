import Foundation
import LeverageKit

/// One call a fake API was asked to make: the operation, its path
/// parameters as the HTTP client would fill them, its key, and its body as
/// JSON (what the HTTP client would send).
public struct FakeCall: Equatable, Sendable {
    public let operation: ContractOperation
    public let path: [String: String]
    public let key: IdempotencyKey?
    public let body: JSONValue?

    public init(
        _ operation: ContractOperation, path: [String: String] = [:], key: IdempotencyKey? = nil,
        body: JSONValue? = nil
    ) {
        self.operation = operation
        self.path = path
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
        body: (any Encodable)? = nil
    ) -> Answers {
        state.record(FakeCall(operation, path: path, key: key, body: body.flatMap { FakeCall.json($0) }))
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
}
