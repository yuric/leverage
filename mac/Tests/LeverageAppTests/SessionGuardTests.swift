import Foundation
import LeverageKit
import LeverageTestSupport
import Testing

@testable import LeverageApp

/// A call the owner's session guard lets through: a 401 on any of them takes
/// the app back to the sign-in screen (MA-6), the Handoff milestone's nine
/// included.
@Suite("Session guard: the Handoff calls")
struct SessionGuardTests {
    private static let id = UUID(uuidString: "00000000-0000-4000-8000-0000000000D1")!

    private static let calls: [(name: String, call: @Sendable (SessionGuard) async throws -> Void)] = [
        ("list_inbox", { _ = try await $0.listInbox(afterSeq: 1, wait: nil) }),
        ("promote_task", { _ = try await $0.promoteTask(taskID: id, key: IdempotencyKey()) }),
        ("edit_contract", {
            _ = try await $0.editContract(
                taskID: id,
                CompleteContractRequest(title: "t", details: nil, criteria: [], workReference: nil),
                key: IdempotencyKey())
        }),
        ("hold_task", { _ = try await $0.holdTask(taskID: id, key: IdempotencyKey()) }),
        ("resume_task", { _ = try await $0.resumeTask(taskID: id, key: IdempotencyKey()) }),
        ("pause_seat", { _ = try await $0.pauseSeat(seatID: id, key: IdempotencyKey()) }),
        ("resume_seat", { _ = try await $0.resumeSeat(seatID: id, key: IdempotencyKey()) }),
        ("change_seat", { _ = try await $0.changeSeat(seatID: id, ChangeSeatRequest(), key: IdempotencyKey()) }),
        ("issue_landing_prompt", {
            _ = try await $0.issueLandingPrompt(seatID: id, connection: .mcp, key: IdempotencyKey())
        }),
        ("sign_in_again", { _ = try await $0.signInAgain(credentialID: id, key: IdempotencyKey()) }),
    ]

    private static func scripted(_ error: (any Error)?, _ fake: FakeOwnerAPI) {
        let outcome: PlainOutcome = .completed(.object([:]), key: "k", command: .cancel)
        let command: @Sendable (UUID, IdempotencyKey) async throws -> PlainOutcome = { _, _ in
            if let error { throw error }
            return outcome
        }
        fake.script {
            $0.listInbox = { _, _ in
                if let error { throw error }
                return InboxPage(items: [], nextAfterSeq: 0)
            }
            $0.promoteTask = command; $0.holdTask = command; $0.resumeTask = command
            $0.pauseSeat = command; $0.resumeSeat = command; $0.signInAgain = command
            $0.editContract = { _, _, _ in
                if let error { throw error }
                return outcome
            }
            $0.issueLandingPrompt = { seatID, connection, key in
                if let error { throw error }
                return AgentFixtures.issuedPrompt(seatID, connection: connection, key: key)
            }
            $0.changeSeat = { _, _, _ in
                if let error { throw error }
                return outcome
            }
        }
    }

    @Test("a call that answers 401 tells the app, and still throws", arguments: calls.map(\.name))
    func unauthenticated(name: String) async throws {
        let call = try #require(Self.calls.first { $0.name == name }).call
        let fake = FakeOwnerAPI()
        Self.scripted(TransportError(code: .unauthenticated, message: "made up"), fake)
        let told = Locked(0)
        let guarded = SessionGuard(base: fake, onUnauthenticated: { told.update { $0 += 1 } })
        await #expect(throws: TransportError.self) { try await call(guarded) }
        #expect(told.value == 1, "\(name)")
    }

    @Test("a call that is refused for another reason does not end the session", arguments: calls.map(\.name))
    func otherError(name: String) async throws {
        let call = try #require(Self.calls.first { $0.name == name }).call
        let fake = FakeOwnerAPI()
        Self.scripted(TransportError(code: .notFound, message: "made up"), fake)
        let told = Locked(0)
        let guarded = SessionGuard(base: fake, onUnauthenticated: { told.update { $0 += 1 } })
        await #expect(throws: TransportError.self) { try await call(guarded) }
        #expect(told.value == 0, "\(name)")
    }

    @Test("a call that succeeds reaches the base once, with its key", arguments: calls.map(\.name))
    func passesThrough(name: String) async throws {
        let call = try #require(Self.calls.first { $0.name == name }).call
        let fake = FakeOwnerAPI()
        Self.scripted(nil, fake)
        let told = Locked(0)
        let guarded = SessionGuard(base: fake, onUnauthenticated: { told.update { $0 += 1 } })
        try await call(guarded)
        #expect(fake.calls.count == 1 && told.value == 0, "\(name)")
    }
}
