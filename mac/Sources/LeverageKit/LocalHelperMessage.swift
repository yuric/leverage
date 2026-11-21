import Foundation

/// The local line sent from the app to the helper's standard input.
public enum LocalHelperMessage: Sendable, HidesToken {
    case token(credentialID: UUID, provider: Provider, token: String)
    case forget(credentialID: UUID)

    public enum CodingError: Error, Equatable, Sendable {
        case invalidLine
    }

    public var fieldsWithoutToken: [(String, String)] {
        [("kind", kind.rawValue), ("credentialID", credentialID.uuidString)]
    }

    /// A UTF-8 JSON object without its terminating LF. Only the local channel
    /// encodes this value.
    public func encodeLine() throws -> Data {
        let message: WireMessage
        switch self {
        case .token(let id, let provider, let token):
            guard provider.kind == .apiToken else { throw CodingError.invalidLine }
            message = WireMessage(version: kind.version, kind: kind, credentialID: id, provider: provider, token: token)
        case .forget(let id):
            message = WireMessage(version: kind.version, kind: kind, credentialID: id, provider: nil, token: nil)
        }
        guard let data = try? JSONEncoder().encode(message) else { throw CodingError.invalidLine }
        return data
    }

    public static func decodeLine(_ line: Data) throws -> Self {
        // Errors are safe to print even if the decoder rejected a field that
        // held a token or a caller supplied an arbitrary line.
        guard !line.contains(0x0A), !line.contains(0x0D),
              let message = try? JSONDecoder().decode(WireMessage.self, from: line),
              message.version == message.kind.version else {
            throw CodingError.invalidLine
        }
        switch message.kind {
        case .token:
            guard let provider = message.provider, provider.kind == .apiToken, let token = message.token else {
                throw CodingError.invalidLine
            }
            return .token(credentialID: message.credentialID, provider: provider, token: token)
        case .forget:
            return .forget(credentialID: message.credentialID)
        }
    }

    private var kind: Kind {
        switch self {
        case .token: return .token
        case .forget: return .forget
        }
    }

    private var credentialID: UUID {
        switch self {
        case .token(let id, _, _), .forget(let id): return id
        }
    }

    private enum Kind: String, Codable {
        case token
        case forget

        // An older helper must refuse a token line whose provider it would ignore.
        var version: Int { self == .token ? 2 : 1 }
    }

    private struct WireMessage: Codable {
        let version: Int
        let kind: Kind
        let credentialID: UUID
        let provider: Provider?
        let token: String?

        enum CodingKeys: String, CodingKey {
            case version, kind, provider, token
            case credentialID = "credential_id"
        }
    }
}
