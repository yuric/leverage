import Foundation
import LeverageKit

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

    var refusalCode: RefusalCode? {
        let value = body["refusal"]?["code"] ?? (status == 409 ? body["code"] : nil)
        return value?.stringValue.flatMap(RefusalCode.init(rawValue:))
    }
}

/// Wrap the shared transport with the generic JSON and HTTP status the tools
/// return. HTTPTransport makes and retries each keyed command.
struct MCPHTTPClient: Sendable {
    let transport: HTTPTransport

    func send(_ request: ToolRequest) async throws -> ToolResponse {
        do {
            switch request.operation.method {
            case .get:
                let value = try await transport.read(
                    request.operation, JSONValue.self, path: request.path, waitSeconds: request.wait)
                return ToolResponse(status: 200, body: value)
            case .post:
                guard let key = request.key else { throw LeverageClientError.invalidBody }
                let outcome = try await transport.command(
                    request.operation, JSONValue.self, path: request.path,
                    body: JSONValue.object(request.body ?? [:]), key: key)
                let status: Int
                switch outcome.outcome {
                case .completed: status = 200
                case .pending: status = 202
                case .refused: status = 409
                }
                return ToolResponse(status: status, body: try json(outcome))
            }
        } catch let error as TransportError {
            return ToolResponse(status: error.status, body: try json(error))
        } catch LeverageClientError.refused(let refusal) {
            return ToolResponse(status: 409, body: try json(refusal))
        } catch LeverageClientError.unexpectedStatus(let status) {
            return ToolResponse(status: status, body: .object([
                "error": .object(["code": .string("unexpected_status"), "message": .string("Unexpected API response.")])
            ]))
        }
    }

    private func json(_ value: some Encodable) throws -> JSONValue {
        try LeverageJSON.decoder().decode(JSONValue.self, from: LeverageJSON.encoder().encode(value))
    }
}
