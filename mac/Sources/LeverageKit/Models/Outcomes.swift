import Foundation

/// The outcome of one command (IF-4): completed with its result (200),
/// pending (202), or refused with its cause (409). `GET /v1/commands/{key}`
/// answers it again.
public struct CommandOutcome<Result: Sendable>: Sendable {
    public let key: String
    public let command: CommandName
    public let outcome: OutcomeKind
    /// The result once completed; nil while pending, when refused, or when
    /// the command returns nothing.
    public let result: Result?
    public let refusal: Refusal?

    public init(key: String, command: CommandName, outcome: OutcomeKind, result: Result?, refusal: Refusal?) {
        self.key = key
        self.command = command
        self.outcome = outcome
        self.result = result
        self.refusal = refusal
    }

    public static func completed(_ result: Result?, key: String, command: CommandName) -> Self {
        Self(key: key, command: command, outcome: .completed, result: result, refusal: nil)
    }

    public static func pending(key: String, command: CommandName) -> Self {
        Self(key: key, command: command, outcome: .pending, result: nil, refusal: nil)
    }

    public static func refused(_ refusal: Refusal, key: String, command: CommandName) -> Self {
        Self(key: key, command: command, outcome: .refused, result: nil, refusal: refusal)
    }

    /// The result of a completed command; throws `refused` or `pending`
    /// otherwise.
    public func completedResult() throws -> Result? {
        switch outcome {
        case .completed: return result
        case .pending: throw LeverageClientError.pending(command)
        case .refused:
            throw LeverageClientError.refused(refusal ?? Refusal(code: .invalidState, ruleID: nil, reason: nil))
        }
    }

    enum CodingKeys: String, CodingKey {
        case key, command, outcome, result, refusal
    }
}

extension CommandOutcome: Equatable where Result: Equatable {}

extension CommandOutcome: Decodable where Result: Decodable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(String.self, forKey: .key)
        command = try container.decode(CommandName.self, forKey: .command)
        outcome = try container.decode(OutcomeKind.self, forKey: .outcome)
        refusal = try container.decodeIfPresent(Refusal.self, forKey: .refusal)
        switch outcome {
        case .completed:
            result = try container.decodeIfPresent(Result.self, forKey: .result)
        case .pending, .refused:
            result = nil
            if try container.decodeNil(forKey: .result) == false {
                throw DecodingError.dataCorruptedError(
                    forKey: .result, in: container, debugDescription: "a \(outcome) outcome has no result")
            }
        }
        if (outcome == .refused) != (refusal != nil) {
            throw DecodingError.dataCorruptedError(
                forKey: .refusal, in: container,
                debugDescription: "a refusal goes with a refused outcome, and only with one")
        }
    }
}

extension CommandOutcome: Encodable where Result: Encodable {
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        try container.encode(command, forKey: .command)
        try container.encode(outcome, forKey: .outcome)
        try container.encode(result, forKey: .result)
        try container.encode(refusal, forKey: .refusal)
    }
}

/// The outcome of a command whose result the contract does not shape: an
/// empty object, null, or a small object its operation names.
public typealias PlainOutcome = CommandOutcome<JSONValue>

extension CommandOutcome where Result == JSONValue {
    /// The `helper_request_id` that Verify, Install, Start and Stop return
    /// (IN-23); nil when the result has none.
    public var helperRequestID: UUID? {
        result?["helper_request_id"]?.stringValue.flatMap(UUID.init(uuidString:))
    }
}

/// Why a command was refused: a registry refusal, with the rule and its
/// reason for `blocked_by_rule`.
public struct Refusal: Codable, Equatable, Sendable {
    public let code: RefusalCode
    public let ruleID: UUID?
    public let reason: String?

    public init(code: RefusalCode, ruleID: UUID?, reason: String?) {
        self.code = code
        self.ruleID = ruleID
        self.reason = reason
    }

    enum CodingKeys: String, CodingKey {
        case code, reason
        case ruleID = "rule_id"
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(code, forKey: .code)
        try container.encodeID(ruleID, forKey: .ruleID)
        try container.encode(reason, forKey: .reason)
    }
}

/// A transport error (IF-3): the request did not reach a command. Thrown by
/// the clients for 400, 401, 404 and 422.
public struct TransportError: Error, Codable, Equatable, Sendable {
    public let code: TransportErrorCode
    public let message: String

    public init(code: TransportErrorCode, message: String) {
        self.code = code
        self.message = message
    }

    /// The HTTP status the code is answered with.
    public var status: Int {
        switch code {
        case .malformed: 400
        case .unauthenticated: 401
        case .notFound: 404
        case .keyReused, .invalid: 422
        }
    }

    private enum Envelope: String, CodingKey { case error }
    private enum Fields: String, CodingKey { case code, message }

    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: Envelope.self)
            .nestedContainer(keyedBy: Fields.self, forKey: .error)
        code = try fields.decode(TransportErrorCode.self, forKey: .code)
        message = try fields.decode(String.self, forKey: .message)
    }

    public func encode(to encoder: any Encoder) throws {
        var envelope = encoder.container(keyedBy: Envelope.self)
        var fields = envelope.nestedContainer(keyedBy: Fields.self, forKey: .error)
        try fields.encode(code, forKey: .code)
        try fields.encode(message, forKey: .message)
    }
}

/// The result of a command that issues a token (§2.1, IN-11): the token
/// the first time the key is answered, and the `*Repeated` form, with the
/// same ids and no token, for a repeat of the key.
public enum TokenAnswer<Shown: Sendable, Repeated: Sendable>: Sendable {
    case shown(Shown)
    case repeated(Repeated)

    private enum Keys: String, CodingKey { case repeated }
}

extension TokenAnswer: Equatable where Shown: Equatable, Repeated: Equatable {}

extension TokenAnswer: Decodable where Shown: Decodable, Repeated: Decodable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        if try container.decodeIfPresent(Bool.self, forKey: .repeated) == true {
            self = .repeated(try Repeated(from: decoder))
        } else {
            self = .shown(try Shown(from: decoder))
        }
    }
}

extension TokenAnswer: Encodable where Shown: Encodable, Repeated: Encodable {
    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .shown(let value): try value.encode(to: encoder)
        case .repeated(let value): try value.encode(to: encoder)
        }
    }
}

public typealias OwnerSessionAnswer = TokenAnswer<OwnerSession, OwnerSessionRepeated>
public typealias HelperTokenAnswer = TokenAnswer<HelperTokenIssued, HelperTokenIssuedRepeated>
public typealias LandingPromptIssuedAnswer = TokenAnswer<LandingPromptIssued, LandingPromptIssuedRepeated>
public typealias SeatTokenPickupAnswer = TokenAnswer<SeatTokenPickup, SeatTokenPickupRepeated>

/// Printed with its token removed, so that a log line or a test failure
/// that shows the value never shows the token.
public protocol HidesToken: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var fieldsWithoutToken: [(String, String)] { get }
}

extension HidesToken {
    public var description: String {
        "\(Self.self)(" + fieldsWithoutToken.map { "\($0.0): \($0.1)" }.joined(separator: ", ") + ")"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(self, children: fieldsWithoutToken.map { (label: Optional($0.0), value: $0.1 as Any) })
    }
}

/// The owner's session, returned once (sign-in and setup).
public struct OwnerSession: Codable, Equatable, Sendable, HidesToken {
    public let userID: UUID
    public let sessionToken: String
    public let createdAt: Date

    public init(userID: UUID, sessionToken: String, createdAt: Date) {
        self.userID = userID
        self.sessionToken = sessionToken
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case sessionToken = "session_token"
        case createdAt = "created_at"
    }

    public var fieldsWithoutToken: [(String, String)] {
        [("userID", userID.contractString), ("sessionToken", "[removed]"), ("createdAt", "\(createdAt)")]
    }
}

public struct OwnerSessionRepeated: Codable, Equatable, Sendable {
    public let userID: UUID
    public let createdAt: Date
    public let repeated: Bool

    public init(userID: UUID, createdAt: Date) {
        self.userID = userID
        self.createdAt = createdAt
        self.repeated = true
    }

    enum CodingKeys: String, CodingKey {
        case repeated
        case userID = "user_id"
        case createdAt = "created_at"
    }
}

/// The helper's token, returned once.
public struct HelperTokenIssued: Codable, Equatable, Sendable, HidesToken {
    public let helperID: UUID
    public let helperToken: String

    public init(helperID: UUID, helperToken: String) {
        self.helperID = helperID
        self.helperToken = helperToken
    }

    enum CodingKeys: String, CodingKey {
        case helperID = "helper_id"
        case helperToken = "helper_token"
    }

    public var fieldsWithoutToken: [(String, String)] {
        [("helperID", helperID.contractString), ("helperToken", "[removed]")]
    }
}

public struct HelperTokenIssuedRepeated: Codable, Equatable, Sendable {
    public let helperID: UUID
    public let repeated: Bool

    public init(helperID: UUID) {
        self.helperID = helperID
        self.repeated = true
    }

    enum CodingKeys: String, CodingKey {
        case repeated
        case helperID = "helper_id"
    }
}

/// A connected seat's ID.
public struct SeatConnected: Codable, Equatable, Sendable {
    public let seatID: UUID

    public init(seatID: UUID) {
        self.seatID = seatID
    }

    enum CodingKeys: String, CodingKey {
        case seatID = "seat_id"
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeID(seatID, forKey: .seatID)
    }
}

/// The first answer to issuing a landing prompt. The text also carries the token.
public struct LandingPromptIssued: Codable, Equatable, Sendable, HidesToken {
    public let seatID: UUID
    public let seatToken: String
    public let text: String
    public let connection: LandingPromptConnection

    public init(seatID: UUID, seatToken: String, text: String, connection: LandingPromptConnection) {
        self.seatID = seatID
        self.seatToken = seatToken
        self.text = text
        self.connection = connection
    }

    enum CodingKeys: String, CodingKey {
        case seatID = "seat_id"
        case seatToken = "seat_token"
        case text, connection
    }

    public var fieldsWithoutToken: [(String, String)] {
        [("seatID", seatID.contractString), ("connection", connection.rawValue)]
    }
}

public struct LandingPromptIssuedRepeated: Codable, Equatable, Sendable {
    public let seatID: UUID
    public let connection: LandingPromptConnection
    public let repeated: Bool

    public init(seatID: UUID, connection: LandingPromptConnection) {
        self.seatID = seatID
        self.connection = connection
        self.repeated = true
    }

    enum CodingKeys: String, CodingKey {
        case seatID = "seat_id"
        case connection, repeated
    }
}

/// A seat's fresh token, picked up by the helper for a run it starts.
public struct SeatTokenPickup: Codable, Equatable, Sendable, HidesToken {
    public let helperRequestID: UUID
    public let seatID: UUID
    public let seatToken: String

    public init(helperRequestID: UUID, seatID: UUID, seatToken: String) {
        self.helperRequestID = helperRequestID
        self.seatID = seatID
        self.seatToken = seatToken
    }

    enum CodingKeys: String, CodingKey {
        case helperRequestID = "helper_request_id"
        case seatID = "seat_id"
        case seatToken = "seat_token"
    }

    public var fieldsWithoutToken: [(String, String)] {
        [("helperRequestID", helperRequestID.contractString), ("seatID", seatID.contractString),
         ("seatToken", "[removed]")]
    }
}

public struct SeatTokenPickupRepeated: Codable, Equatable, Sendable {
    public let helperRequestID: UUID
    public let seatID: UUID
    public let repeated: Bool

    public init(helperRequestID: UUID, seatID: UUID) {
        self.helperRequestID = helperRequestID
        self.seatID = seatID
        self.repeated = true
    }

    enum CodingKeys: String, CodingKey {
        case repeated
        case helperRequestID = "helper_request_id"
        case seatID = "seat_id"
    }
}
