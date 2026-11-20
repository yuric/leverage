import Foundation
import LeverageKit
import LeverageTestSupport
import Testing

@testable import LeverageApp

/// The Rule checks milestone's ten owner calls go through the owner's session
/// guard too: a 401 on any of them takes the app back to the sign-in screen
/// (MA-6).
@Suite("Session guard: the rule and check calls")
struct SessionGuardRuleChecksTests {
    private static let id = UUID(uuidString: "00000000-0000-4000-8000-0000000000D2")!

    private static let calls: [(name: String, call: @Sendable (SessionGuard) async throws -> Void)] = [
        ("list_rules", { _ = try await $0.listRules() }),
        ("add_rule", {
            _ = try await $0.addRule(
                AddRuleRequest(name: "n", instruction: "i", hook: .taskBeforeReady, scope: .allTasks),
                key: IdempotencyKey())
        }),
        ("save_rule", {
            _ = try await $0.saveRule(
                ruleID: id, SaveRuleRequest(name: "n", instruction: "i", scope: .allTasks, onFail: .block, route: nil),
                key: IdempotencyKey())
        }),
        ("enable_rule", { _ = try await $0.enableRule(ruleID: id, key: IdempotencyKey()) }),
        ("disable_rule", { _ = try await $0.disableRule(ruleID: id, key: IdempotencyKey()) }),
        ("revert_rule", { _ = try await $0.revertRule(ruleID: id, key: IdempotencyKey()) }),
        ("remove_rule", { _ = try await $0.removeRule(ruleID: id, key: IdempotencyKey()) }),
        ("rerun_check", { _ = try await $0.rerunCheck(checkID: id, key: IdempotencyKey()) }),
        ("override_check", {
            _ = try await $0.overrideCheck(checkID: id, OverrideCheckRequest(reason: "r"), key: IdempotencyKey())
        }),
        ("draft_contract", { _ = try await $0.draftContract(taskID: id, key: IdempotencyKey()) }),
    ]

    private static func scripted(_ error: (any Error)?, _ fake: FakeOwnerAPI) {
        let outcome: PlainOutcome = .completed(.object([:]), key: "k", command: .cancel)
        let command: @Sendable (UUID, IdempotencyKey) async throws -> PlainOutcome = { _, _ in
            if let error { throw error }
            return outcome
        }
        fake.script {
            $0.listRules = {
                if let error { throw error }
                return RulesList(rules: [])
            }
            $0.addRule = { _, _ in
                if let error { throw error }
                return outcome
            }
            $0.saveRule = { _, _, _ in
                if let error { throw error }
                return outcome
            }
            $0.enableRule = command; $0.disableRule = command; $0.revertRule = command; $0.removeRule = command
            $0.rerunCheck = command
            $0.overrideCheck = { _, _, _ in
                if let error { throw error }
                return outcome
            }
            $0.draftContract = { _, _ in
                if let error { throw error }
                return .completed(DraftContractResult(jobID: UUID()), key: "k", command: .draftContract)
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
