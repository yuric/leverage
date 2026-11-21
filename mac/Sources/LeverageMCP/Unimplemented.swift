import Foundation
import LeverageKit

struct ActivityWindow {
    mutating func recordCall(at time: Duration) {}
    func isOpen(at time: Duration) -> Bool { false }
}

struct HeldWork {
    enum Item: Equatable {
        case task(String)
        case review(String)
    }
    var item: Item? { nil }
    mutating func observe(_ request: ToolRequest, response: ToolResponse) {}
    func hasStartedCriterion(task: String, criterion: String) -> Bool { false }
    func hasStartedAction(task: String, action: String) -> Bool { false }
}

struct ToolDefinition {
    let operation: ContractOperation
    var name: String { operation.rawValue }
    let description: String
    let inputSchema: [String: JSONValue]
}

struct ToolCatalog {
    init(role: SeatRole? = nil) {}
    var tools: [ToolDefinition] { [] }
    func tool(named name: String) -> ToolDefinition? { nil }
}

struct ToolRequest: Equatable, Sendable {
    let operation: ContractOperation
    var path: [String: String] = [:]
    var body: [String: JSONValue]?
    var key: IdempotencyKey?
    var wait: Int?
}

struct ToolResponse: Sendable {
    let status: Int
    let body: JSONValue
}

struct ToolResult: Sendable {
    let response: ToolResponse?
    let isError: Bool
    let key: IdempotencyKey?
}

struct MCPHTTPClient: Sendable {
    init(transport: HTTPTransport) {}
    func send(_ request: ToolRequest) async throws -> ToolResponse {
        ToolResponse(status: 500, body: .null)
    }
}

actor ToolCaller {
    init(
        transport: @escaping @Sendable (ToolRequest) async throws -> ToolResponse,
        now: @escaping @Sendable () -> Duration = { .zero }
    ) {}
    func call(_ tool: ToolDefinition, arguments: [String: JSONValue]) async -> ToolResult {
        ToolResult(response: nil, isError: true, key: nil)
    }
    func heartbeat() async {}
}

struct HeartbeatPump {
    init(caller: ToolCaller, sleep: @escaping @Sendable (Duration) async throws -> Void) {}
    func run() async {}
}

struct MCPServer: Sendable {
    init(
        input: FileHandle, output: FileHandle, caller: ToolCaller, catalog: ToolCatalog,
        log: Log, token: String
    ) {}
    func run() async throws {}
}
