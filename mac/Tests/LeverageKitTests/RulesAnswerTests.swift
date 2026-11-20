import Foundation
import LeverageTestSupport
import Testing
@testable import LeverageKit

// GET /v1/owner/rules as the server answered it right after sign-up, read
// from a compose project of milestone 4's own (track F2): the seven shipped
// rules in shipped_rules.json's order. shipped_rules.json holds a
// placeholder object, {"to_be_written_in": ...}, as the instruction of
// "The orchestrator approves outward actions itself"; the server writes
// that version with no instruction and sends null, which RuleVersion's
// optional instruction reads. Only the ids and times are the run's own.

@Suite("The rules answer")
struct RulesAnswerTests {
    static let afterSignUp = #"""
        {
          "rules": [
            {
              "rule": {
                "id": "a1f5e4f5-41a1-49d8-bea8-d6bc7528e7ed",
                "key": "acceptance_criteria",
                "enabled": true,
                "current_version": 1
              },
              "version": {
                "id": "79852043-ee4a-4800-984c-8ecf40ffa3fe",
                "rule_id": "a1f5e4f5-41a1-49d8-bea8-d6bc7528e7ed",
                "version": 1,
                "key": "acceptance_criteria",
                "name": "Every task needs acceptance criteria",
                "hook": "task.before_ready",
                "scope": {
                  "kind": "all_tasks",
                  "project_ids": null,
                  "action_kinds": null
                },
                "kind": "gate",
                "checker": "app",
                "on_fail": "block",
                "route": "owner",
                "queue_timeout_seconds": null,
                "run_timeout_seconds": null,
                "instruction": null,
                "parameters": {
                  "minimum_count": 1
                },
                "origin": "shipped",
                "author_kind": "owner",
                "author_id": "3ebd52d1-ba10-4c7a-ba63-3afc34c7cd75",
                "created_at": "2026-11-20T17:36:19.508042Z"
              },
              "sentence": "Every task needs at least 1 acceptance criterion besides the review.",
              "moment_name": "when a task is ready to start",
              "acts": true,
              "stats": {
                "checks": 0,
                "average_seconds": null,
                "tokens": 0,
                "spend": 0.0,
                "overrides": 0
              }
            },
            {
              "rule": {
                "id": "c14e859d-a2fd-4f61-866f-8646bc8f3758",
                "key": "specific_details",
                "enabled": true,
                "current_version": 1
              },
              "version": {
                "id": "f72af43e-6c81-44ac-bfe2-ff357121644e",
                "rule_id": "c14e859d-a2fd-4f61-866f-8646bc8f3758",
                "version": 1,
                "key": "specific_details",
                "name": "Every task needs specific details",
                "hook": "task.before_ready",
                "scope": {
                  "kind": "all_tasks",
                  "project_ids": null,
                  "action_kinds": null
                },
                "kind": "gate",
                "checker": "model",
                "on_fail": "block",
                "route": "owner",
                "queue_timeout_seconds": null,
                "run_timeout_seconds": null,
                "instruction": "A task has specific details when someone who has never seen it could do it, and a reviewer could tell done from not done, from its goal, its details and its acceptance criteria alone. Pass it when all three hold: the goal says what is to be made or changed, and where; the goal or the details say who or what it is for, or what it must include or avoid; and at least one acceptance criterion names something that can be seen or checked. Fail it when the goal could mean several different pieces of work, when it only says that something should be better, fixed or updated without saying what, or when no criterion can be checked. Do not fail a task for being short, for its style, or for leaving out what its criteria do not need. Do not judge whether the task is worth doing.",
                "parameters": {},
                "origin": "shipped",
                "author_kind": "owner",
                "author_id": "3ebd52d1-ba10-4c7a-ba63-3afc34c7cd75",
                "created_at": "2026-11-20T17:36:19.508042Z"
              },
              "sentence": null,
              "moment_name": "when a task is ready to start",
              "acts": true,
              "stats": {
                "checks": 0,
                "average_seconds": null,
                "tokens": 0,
                "spend": 0.0,
                "overrides": 0
              }
            },
            {
              "rule": {
                "id": "6f8b6fcd-af31-4d6e-8d1d-ae761ab05262",
                "key": "ask_orchestrator_first",
                "enabled": true,
                "current_version": 1
              },
              "version": {
                "id": "11b41ce2-df9f-40cb-92bd-d2e9c10e332e",
                "rule_id": "6f8b6fcd-af31-4d6e-8d1d-ae761ab05262",
                "version": 1,
                "key": "ask_orchestrator_first",
                "name": "Workers ask the orchestrator before they ask you",
                "hook": "question.asked",
                "scope": {
                  "kind": "all_tasks",
                  "project_ids": null,
                  "action_kinds": null
                },
                "kind": "policy",
                "checker": "app",
                "on_fail": null,
                "route": null,
                "queue_timeout_seconds": null,
                "run_timeout_seconds": null,
                "instruction": null,
                "parameters": {},
                "origin": "shipped",
                "author_kind": "owner",
                "author_id": "3ebd52d1-ba10-4c7a-ba63-3afc34c7cd75",
                "created_at": "2026-11-20T17:36:19.508042Z"
              },
              "sentence": "Workers ask the orchestrator before they ask you.",
              "moment_name": "when a worker asks a question",
              "acts": false,
              "stats": {
                "checks": 0,
                "average_seconds": null,
                "tokens": 0,
                "spend": 0.0,
                "overrides": 0
              }
            },
            {
              "rule": {
                "id": "5d405f73-d879-4784-8ded-80c3580a2a95",
                "key": "different_provider_review",
                "enabled": true,
                "current_version": 1
              },
              "version": {
                "id": "6403a3ea-6dd7-4fd8-90d3-32e8ff8eb697",
                "rule_id": "5d405f73-d879-4784-8ded-80c3580a2a95",
                "version": 1,
                "key": "different_provider_review",
                "name": "A different provider reviews every task",
                "hook": "review.assign",
                "scope": {
                  "kind": "all_tasks",
                  "project_ids": null,
                  "action_kinds": null
                },
                "kind": "policy",
                "checker": "app",
                "on_fail": null,
                "route": null,
                "queue_timeout_seconds": null,
                "run_timeout_seconds": null,
                "instruction": null,
                "parameters": {},
                "origin": "shipped",
                "author_kind": "owner",
                "author_id": "3ebd52d1-ba10-4c7a-ba63-3afc34c7cd75",
                "created_at": "2026-11-20T17:36:19.508042Z"
              },
              "sentence": "An agent on a provider that built the task may not review it.",
              "moment_name": "when a reviewer claims a review",
              "acts": true,
              "stats": {
                "checks": 0,
                "average_seconds": null,
                "tokens": 0,
                "spend": 0.0,
                "overrides": 0
              }
            },
            {
              "rule": {
                "id": "e3b9382d-0189-48fd-a8a9-9124a1061391",
                "key": "escalate_after_failed_reviews",
                "enabled": true,
                "current_version": 1
              },
              "version": {
                "id": "76d98f94-f815-4cfb-9d06-6676159f28f0",
                "rule_id": "e3b9382d-0189-48fd-a8a9-9124a1061391",
                "version": 1,
                "key": "escalate_after_failed_reviews",
                "name": "Repeated failed reviews move a task to a stronger model",
                "hook": "review.failed",
                "scope": {
                  "kind": "all_tasks",
                  "project_ids": null,
                  "action_kinds": null
                },
                "kind": "policy",
                "checker": "app",
                "on_fail": null,
                "route": null,
                "queue_timeout_seconds": null,
                "run_timeout_seconds": null,
                "instruction": null,
                "parameters": {
                  "threshold": 2
                },
                "origin": "shipped",
                "author_kind": "owner",
                "author_id": "3ebd52d1-ba10-4c7a-ba63-3afc34c7cd75",
                "created_at": "2026-11-20T17:36:19.508042Z"
              },
              "sentence": "After 2 failed reviews a task moves to a stronger model.",
              "moment_name": "when a review fails",
              "acts": false,
              "stats": {
                "checks": 0,
                "average_seconds": null,
                "tokens": 0,
                "spend": 0.0,
                "overrides": 0
              }
            },
            {
              "rule": {
                "id": "0f0f1e11-affa-467a-aab2-6492ecbb4568",
                "key": "project_budget_pause",
                "enabled": true,
                "current_version": 1
              },
              "version": {
                "id": "1457e2a3-bb99-4697-8c92-a58497bb041e",
                "rule_id": "0f0f1e11-affa-467a-aab2-6492ecbb4568",
                "version": 1,
                "key": "project_budget_pause",
                "name": "Projects pause when they reach their budget",
                "hook": "cost.reported",
                "scope": {
                  "kind": "all_tasks",
                  "project_ids": null,
                  "action_kinds": null
                },
                "kind": "policy",
                "checker": "app",
                "on_fail": null,
                "route": null,
                "queue_timeout_seconds": null,
                "run_timeout_seconds": null,
                "instruction": null,
                "parameters": {},
                "origin": "shipped",
                "author_kind": "owner",
                "author_id": "3ebd52d1-ba10-4c7a-ba63-3afc34c7cd75",
                "created_at": "2026-11-20T17:36:19.508042Z"
              },
              "sentence": "A project pauses when it reaches its budget.",
              "moment_name": "when spending is reported",
              "acts": false,
              "stats": {
                "checks": 0,
                "average_seconds": null,
                "tokens": 0,
                "spend": 0.0,
                "overrides": 0
              }
            },
            {
              "rule": {
                "id": "88c952ef-3868-4c73-8f36-911d36f37186",
                "key": "orchestrator_approves_actions",
                "enabled": true,
                "current_version": 1
              },
              "version": {
                "id": "aa094407-5c4e-451a-b539-7a60ee4cf308",
                "rule_id": "88c952ef-3868-4c73-8f36-911d36f37186",
                "version": 1,
                "key": "orchestrator_approves_actions",
                "name": "The orchestrator approves outward actions itself",
                "hook": "action.requested",
                "scope": {
                  "kind": "all_tasks",
                  "project_ids": null,
                  "action_kinds": null
                },
                "kind": "policy",
                "checker": "model",
                "on_fail": null,
                "route": null,
                "queue_timeout_seconds": null,
                "run_timeout_seconds": null,
                "instruction": null,
                "parameters": {},
                "origin": "shipped",
                "author_kind": "owner",
                "author_id": "3ebd52d1-ba10-4c7a-ba63-3afc34c7cd75",
                "created_at": "2026-11-20T17:36:19.508042Z"
              },
              "sentence": null,
              "moment_name": "before anything goes out",
              "acts": false,
              "stats": {
                "checks": 0,
                "average_seconds": null,
                "tokens": 0,
                "spend": 0.0,
                "overrides": 0
              }
            }
          ]
        }
        """#

    @Test("the Mac reads the server's whole answer after sign-up, the approvals rule with no instruction")
    func readsTheAnswerAfterSignUp() async throws {
        let host = "rules-after-sign-up.test"
        let session = StubURLProtocol.session(host: host, answer: .init(status: 200, json: Self.afterSignUp))
        let client = OwnerClient(baseURL: URL(string: "http://\(host)")!, sessionToken: "lvo_x", session: session)

        let list = try await client.listRules()

        #expect(list.rules.map(\.rule.key) == [
            "acceptance_criteria", "specific_details", "ask_orchestrator_first", "different_provider_review",
            "escalate_after_failed_reviews", "project_budget_pause", "orchestrator_approves_actions",
        ])
        let approvals = try #require(list.rules.last)
        #expect(approvals.version.checker == .model)
        #expect(approvals.version.instruction == nil)
        #expect(approvals.sentence == nil)
        #expect(approvals.acts == false)
        let details = try #require(list.rules.first { $0.rule.key == "specific_details" })
        #expect(details.version.instruction?.hasPrefix("A task has specific details") == true)
        #expect(list.rules.filter { $0.version.checker == .app }.allSatisfy { $0.version.instruction == nil })
    }
}
