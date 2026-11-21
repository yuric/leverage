import Foundation

public enum LocalHelperMessage: Sendable {
    case token(credentialID: UUID, token: String)
    case forget(credentialID: UUID)

    public enum CodingError: Error, Equatable, Sendable {
        case invalidLine
    }

    public func encodeLine() throws -> Data {
        throw CodingError.invalidLine
    }

    public static func decodeLine(_ line: Data) throws -> Self {
        throw CodingError.invalidLine
    }
}
