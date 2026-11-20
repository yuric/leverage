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

    func landingPrompt(seatID: UUID) async throws -> LandingPrompt {
        try await guarded { try await base.landingPrompt(seatID: seatID) }
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
        -> CommandOutcome<SeatConnectedAnswer> {
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
}

/// The helper's token comes from `issue_helper_token`: this hands any
/// `OwnerAPI` to the helper supervisor as its issuer.
struct OwnerHelperTokenIssuer: HelperTokenIssuing {
    let owner: any OwnerAPI

    func issueHelperToken(name: String, idempotencyKey: String) async throws -> String? {
        try await owner.issueHelperToken(name: name, idempotencyKey: idempotencyKey)
    }
}
