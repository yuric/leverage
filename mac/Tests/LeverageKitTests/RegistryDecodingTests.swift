import Foundation
import Testing

// The Mac side reads the contract's registry with plain Codable structs and
// no custom decoding. SwiftPM takes no resources from outside mac/, so the
// test finds api/contract/registry.json from this file's own path.

struct ContractRegistry: Decodable {
    struct EventType: Decodable {
        let type: String
        let group: String
        let subjectKinds: [String?]
        let schemaVersions: [Int]
        let writtenAsSideEvent: Bool

        enum CodingKeys: String, CodingKey {
            case type, group
            case subjectKinds = "subject_kinds"
            case schemaVersions = "schema_versions"
            case writtenAsSideEvent = "written_as_side_event"
        }
    }

    struct HoldReason: Decodable {
        let reason: String
        let leaseClock: String
        let inBlocked: Bool
        let step: String
        let needsYouItem: String?

        enum CodingKeys: String, CodingKey {
            case reason, step
            case leaseClock = "lease_clock"
            case inBlocked = "in_blocked"
            case needsYouItem = "needs_you_item"
        }
    }

    struct Refusal: Decodable {
        let code: String
        let precedence: Int?
        let claimsOnly: Bool
        let ownerOnly: Bool

        enum CodingKeys: String, CodingKey {
            case code, precedence
            case claimsOnly = "claims_only"
            case ownerOnly = "owner_only"
        }
    }

    struct ReleaseReason: Decodable {
        let reason: String
        let chosenBy: String

        enum CodingKeys: String, CodingKey {
            case reason
            case chosenBy = "chosen_by"
        }
    }

    struct Operation: Decodable {
        let operationId: String
        let method: String
        let path: String
        let caller: String
        let commands: [String]
        let tag: String

        enum CodingKeys: String, CodingKey {
            case method, path, caller, commands, tag
            case operationId = "operation_id"
        }
    }

    struct JobKind: Decodable {
        let kind: String
        let inputComponent: String
        let resultComponent: String

        enum CodingKeys: String, CodingKey {
            case kind
            case inputComponent = "input_component"
            case resultComponent = "result_component"
        }
    }

    struct CredentialProvider: Decodable {
        let provider: String
        let kind: String
        let providerGroup: String

        enum CodingKeys: String, CodingKey {
            case provider, kind
            case providerGroup = "provider_group"
        }
    }

    let eventTypes: [EventType]
    let holdReasons: [HoldReason]
    let refusals: [Refusal]
    let checkResults: [String]
    let releaseReasons: [ReleaseReason]
    let nextKinds: [String]
    let stepKinds: [String]
    let needsYouItems: [String]
    let hooks: [String]
    let customRuleHooks: [String]
    let commands: [String]
    let operations: [Operation]
    let jobKinds: [JobKind]
    let guards: [String]
    let dueTimeSources: [String]
    let policyEffects: [String: [String]]
    let credentialProviders: [CredentialProvider]
    let lists: [String: [String]]

    enum CodingKeys: String, CodingKey {
        case refusals, hooks, commands, operations, guards, lists
        case eventTypes = "event_types"
        case holdReasons = "hold_reasons"
        case checkResults = "check_results"
        case releaseReasons = "release_reasons"
        case nextKinds = "next_kinds"
        case stepKinds = "step_kinds"
        case needsYouItems = "needs_you_items"
        case customRuleHooks = "custom_rule_hooks"
        case jobKinds = "job_kinds"
        case dueTimeSources = "due_time_sources"
        case policyEffects = "policy_effects"
        case credentialProviders = "credential_providers"
    }
}

@Suite("Contract registry")
struct RegistryDecodingTests {
    static let registryURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // LeverageKitTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // mac
        .deletingLastPathComponent()  // repository root
        .appendingPathComponent("api/contract/registry.json")

    static func decode() throws -> ContractRegistry {
        // Explicit coding keys, not .convertFromSnakeCase: that strategy
        // would also rewrite the keys of `lists` ("task_states").
        try JSONDecoder().decode(ContractRegistry.self, from: Data(contentsOf: registryURL))
    }

    @Test("decodes registry.json into plain Codable structs")
    func decodes() throws {
        let registry = try Self.decode()
        #expect(!registry.eventTypes.isEmpty)
        #expect(!registry.holdReasons.isEmpty)
        #expect(!registry.operations.isEmpty)
    }

    @Test("decodes lists as a dictionary of string arrays, with the task states")
    func taskStates() throws {
        let registry = try Self.decode()
        #expect(registry.lists["task_states"] == [
            "ideas", "backlog", "ready", "working", "in_review", "finishing", "done", "cancelled",
        ])
    }

    @Test("keeps a missing subject kind and a missing precedence as nil")
    func optionals() throws {
        let registry = try Self.decode()
        let notEligible = registry.refusals.first { $0.code == "not_eligible" }
        #expect(notEligible != nil)
        #expect(notEligible?.precedence == nil)
        let costReported = registry.eventTypes.first { $0.type == "cost.reported" }
        #expect(costReported?.subjectKinds.contains(nil) == true)
    }
}
