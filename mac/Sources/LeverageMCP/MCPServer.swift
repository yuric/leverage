import Foundation
import LeverageKit

/// One stdio session. Dispatch each request to completion before taking the
/// next one, including requests received in one JSON-RPC batch.
struct MCPServer: Sendable {
    private static let defaultRevision = "2025-06-18"
    private static let revisions = ["2025-11-25", defaultRevision, "2025-03-26", "2024-11-05"]

    private let stdio: StdioTransport
    private let caller: ToolCaller
    private let catalog: ToolCatalog
    private let log: Log
    private let token: String

    init(
        input: FileHandle, output: FileHandle, caller: ToolCaller, catalog: ToolCatalog,
        log: Log, token: String
    ) {
        stdio = StdioTransport(input: input, output: output)
        self.caller = caller
        self.catalog = catalog
        self.log = log
        self.token = token
    }

    func run() async throws {
        async let _: Void = HeartbeatPump(caller: caller).run()
        try await readRequests()
        // Cancelled and joined by the async-let scope on EOF or I/O error.
    }

    private func readRequests() async throws {
        while let line = await stdio.nextLine() {
            guard let value = try? JSONRPC.decode(line) else {
                try stdio.write(JSONRPC.error(.parseError))
                continue
            }
            if let batch = value as? [Any] {
                if batch.isEmpty {
                    try stdio.write(JSONRPC.error(.invalidRequest))
                    continue
                }
                var replies: [JSONRPC.Object] = []
                for request in batch {
                    if let reply = await dispatch(request) { replies.append(reply) }
                }
                if !replies.isEmpty { try stdio.write(replies) }
            } else if let reply = await dispatch(value) {
                try stdio.write(reply)
            }
        }
    }

    private func dispatch(_ value: Any) async -> JSONRPC.Object? {
        guard let request = JSONRPC.Request(value) else { return JSONRPC.error(.invalidRequest) }
        // A notification, including notifications/initialized, has no reply.
        guard let id = request.id else { return nil }
        if let text = id as? String, text.contains(token) { return JSONRPC.error(.invalidRequest) }

        let params = request.params as? JSONRPC.Object
        guard request.params == nil || params != nil else { return JSONRPC.error(.invalidParams, id: id) }
        switch request.method {
        case "initialize":
            guard let revision = params?["protocolVersion"] as? String else {
                return JSONRPC.error(.invalidParams, id: id)
            }
            return JSONRPC.result(initialize(revision: revision), id: id)
        case "ping":
            return JSONRPC.result([:], id: id)
        case "tools/list":
            return JSONRPC.result(["tools": catalog.tools.map(\.wireValue)], id: id)
        case "tools/call":
            guard let name = params?["name"] as? String, let tool = catalog.tool(named: name),
                  let arguments = Self.arguments(params?["arguments"]) else {
                await caller.recordActivity()
                return JSONRPC.error(.invalidParams, id: id)
            }
            let result = await caller.call(tool, arguments: arguments)
            guard let payload = try? LeverageJSON.encoder().encode(result.payload.removingToken(token)) else {
                return JSONRPC.error(.internalError, id: id)
            }
            return JSONRPC.result([
                "isError": result.isError,
                "content": [["type": "text", "text": String(decoding: payload, as: UTF8.self)]]
            ], id: id)
        default:
            return JSONRPC.error(.methodNotFound, id: id)
        }
    }

    private func initialize(revision: String) -> JSONRPC.Object {
        // Only a revision-shaped value belongs in the log. Other strings
        // are untrusted input, and can contain content or credentials.
        if revision.utf8.count == 10, revision.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#,
                                                      options: .regularExpression) != nil {
            log.info("MCP initialize protocol revision \(Redaction.redact(revision, removing: [token]))")
        } else {
            log.info("MCP initialize protocol revision unrecognized")
        }
        return [
            "protocolVersion": Self.revisions.contains(revision) ? revision : Self.defaultRevision,
            "capabilities": ["tools": JSONRPC.Object()],
            "serverInfo": ["name": "leverage", "version": leverageMacVersion]
        ]
    }

    private static func arguments(_ value: Any?) -> [String: JSONValue]? {
        guard let value else { return [:] }
        guard let fields = value as? JSONRPC.Object, let data = try? JSONSerialization.data(withJSONObject: fields) else {
            return nil
        }
        return try? LeverageJSON.decoder().decode([String: JSONValue].self, from: data)
    }
}
