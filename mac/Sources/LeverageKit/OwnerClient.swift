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

    public init(baseURL: URL, sessionToken: String?, session: URLSession = .shared) {
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

    public func landingPrompt(seatID: UUID) async throws -> LandingPrompt {
        try await transport.read(.getLandingPrompt, path: ["id": seatID.contractString])
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
        -> CommandOutcome<SeatConnectedAnswer> {
        try await transport.command(.connectSeat, body: request, key: key)
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
        throw LeverageClientError.invalidBody
    }

    public func addRule(_ request: AddRuleRequest, key: IdempotencyKey) async throws -> PlainOutcome {
        throw LeverageClientError.invalidBody
    }

    public func saveRule(ruleID: UUID, _ request: SaveRuleRequest, key: IdempotencyKey) async throws
        -> PlainOutcome {
        throw LeverageClientError.invalidBody
    }

    public func enableRule(ruleID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        throw LeverageClientError.invalidBody
    }

    public func disableRule(ruleID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        throw LeverageClientError.invalidBody
    }

    public func revertRule(ruleID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        throw LeverageClientError.invalidBody
    }

    public func removeRule(ruleID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        throw LeverageClientError.invalidBody
    }

    public func rerunCheck(checkID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        throw LeverageClientError.invalidBody
    }

    public func overrideCheck(checkID: UUID, _ request: OverrideCheckRequest, key: IdempotencyKey) async throws
        -> PlainOutcome {
        throw LeverageClientError.invalidBody
    }

    public func draftContract(taskID: UUID, key: IdempotencyKey) async throws
        -> CommandOutcome<DraftContractResult> {
        throw LeverageClientError.invalidBody
    }
}
