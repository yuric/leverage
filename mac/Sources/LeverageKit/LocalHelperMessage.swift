import Foundation

/// The local line sent from the app to the helper's standard input.
public enum LocalHelperMessage: Sendable, HidesToken {
    case token(credentialID: UUID, token: String)
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
        let token: String?
        switch self {
        case .token(_, let value): token = value
        case .forget: token = nil
        }
        let message = WireMessage(version: Self.version, kind: kind, credentialID: credentialID, token: token)
        guard let data = try? JSONEncoder().encode(message) else { throw CodingError.invalidLine }
        return data
    }

    public static func decodeLine(_ line: Data) throws -> Self {
        // Errors are safe to print even if the decoder rejected a field that
        // held a token or a caller supplied an arbitrary line.
        guard !line.contains(0x0A), !line.contains(0x0D),
              let message = try? JSONDecoder().decode(WireMessage.self, from: line),
              message.version == version else {
            throw CodingError.invalidLine
        }
        switch message.kind {
        case .token:
            guard let token = message.token else { throw CodingError.invalidLine }
            return .token(credentialID: message.credentialID, token: token)
        case .forget:
            return .forget(credentialID: message.credentialID)
        }
    }

    private static let version = 1

    private var kind: Kind {
        switch self {
        case .token: return .token
        case .forget: return .forget
        }
    }

    private var credentialID: UUID {
        switch self {
        case .token(let id, _), .forget(let id): return id
        }
    }

    private enum Kind: String, Codable {
        case token
        case forget
    }

    private struct WireMessage: Codable {
        let version: Int
        let kind: Kind
        let credentialID: UUID
        let token: String?

        enum CodingKeys: String, CodingKey {
            case version, kind, token
            case credentialID = "credential_id"
        }
    }
}
