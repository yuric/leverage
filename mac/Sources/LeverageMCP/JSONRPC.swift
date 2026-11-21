import Foundation
import CoreFoundation
import LeverageKit

enum JSONRPC {
    typealias Object = [String: Any]

    struct Request {
        let id: Any?
        let method: String
        let params: Any?

        init?(_ value: Any) {
            guard let fields = value as? Object,
                  fields["jsonrpc"] as? String == "2.0",
                  let method = fields["method"] as? String else { return nil }
            let id = fields["id"]
            guard id == nil || JSONRPC.isIdentifier(id) else { return nil }
            self.id = id
            self.method = method
            params = fields["params"]
        }
    }

    enum Fault: Int {
        case parseError = -32700
        case invalidRequest = -32600
        case methodNotFound = -32601
        case invalidParams = -32602
        case internalError = -32603

        var message: String {
            switch self {
            case .parseError: "Parse error"
            case .invalidRequest: "Invalid Request"
            case .methodNotFound: "Method not found"
            case .invalidParams: "Invalid params"
            case .internalError: "Internal error"
            }
        }
    }

    static func decode(_ line: Data) throws -> Any {
        try JSONSerialization.jsonObject(with: line, options: [.fragmentsAllowed])
    }

    static func result(_ body: Object, id: Any) -> Object {
        ["jsonrpc": "2.0", "id": id, "result": body]
    }

    static func error(_ fault: Fault, id: Any = NSNull()) -> Object {
        ["jsonrpc": "2.0", "id": id, "error": ["code": fault.rawValue, "message": fault.message]]
    }

    private static func isIdentifier(_ value: Any?) -> Bool {
        if value is String || value is NSNull { return true }
        // JSONSerialization bridges both booleans and numbers to NSNumber.
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) != CFBooleanGetTypeID()
    }
}

extension JSONValue {
    /// A value JSONSerialization can write without changing its JSON type.
    var foundationValue: Any {
        switch self {
        case .null: NSNull()
        case .bool(let value): value
        case .number(let value): value
        case .string(let value): value
        case .array(let values): values.map(\.foundationValue)
        case .object(let fields): fields.mapValues(\.foundationValue)
        }
    }

    /// Preserve normal tool data. Only the configured seat token is removed
    /// before the reply is encoded, including inside quoted or nested JSON.
    func removingToken(_ token: String) -> JSONValue {
        switch self {
        case .string(let value): .string(value.replacingOccurrences(of: token, with: "[removed]"))
        case .array(let values): .array(values.map { $0.removingToken(token) })
        case .object(let fields):
            .object(fields.reduce(into: [:]) { result, field in
                let key = field.key.replacingOccurrences(of: token, with: "[removed]")
                result[key] = field.value.removingToken(token)
            })
        default: self
        }
    }
}
