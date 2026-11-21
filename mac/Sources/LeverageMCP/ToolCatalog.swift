import Foundation
import LeverageKit

struct ToolDefinition: Sendable {
    let operation: ContractOperation
    var name: String { operation.rawValue }
    let description: String
    let inputSchema: [String: JSONValue]

    var wireValue: JSONRPC.Object {
        ["name": name, "description": description, "inputSchema": inputSchema.mapValues(\.foundationValue)]
    }
}

struct ToolCatalog: Sendable {
    let tools: [ToolDefinition]

    init(role: SeatRole? = nil) {
        if let role {
            tools = Self.all.filter { $0.roles.contains(role) }.map(\.definition)
        } else {
            tools = Self.all.map(\.definition)
        }
    }

    func tool(named name: String) -> ToolDefinition? {
        tools.first { $0.name == name }
    }

    private static let all: [(definition: ToolDefinition, roles: [SeatRole])] = AgentTools.all.map { tool in
        // These documents are checked by the generator and contain only
        // contracts compiled into this binary.
        let operation = ContractOperation(rawValue: tool.id)!
        var schema = try! LeverageJSON.decoder().decode([String: JSONValue].self, from: Data(tool.inputSchema.utf8))
        var properties = schema["properties"]?.objectValue ?? [:]
        if operation.method == .post {
            properties["idempotency_key"] = .object([
                "type": .string("string"), "minLength": .number(1), "maxLength": .number(128),
                "pattern": .string("^[A-Za-z0-9_-]+$"),
                "description": .string("Reuse the returned key when retrying the same command.")
            ])
        }
        if operation == .getNext {
            properties["wait"] = .object([
                "type": .string("integer"), "minimum": .number(0), "maximum": .number(Double(NextWait.maximum)),
                "default": .number(Double(NextWait.defaultSeconds))
            ])
        }
        schema["properties"] = .object(properties)

        let description = operation == .startAction
            ? tool.summary + " Call this tool before carrying out the action."
            : tool.summary
        return (ToolDefinition(operation: operation, description: description, inputSchema: schema), tool.roles)
    }
}

enum NextWait {
    static let maximum = 30
    static let defaultSeconds = 20
}
