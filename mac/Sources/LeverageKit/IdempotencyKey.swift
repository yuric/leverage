import Foundation

/// The `Idempotency-Key` of one command (IN-8): a new key per command, and
/// the same key when the same command is sent again, so that a repeat
/// writes nothing and answers the command's outcome.
public struct IdempotencyKey: Hashable, Codable, Sendable, CustomStringConvertible {
    public let value: String

    /// A new key: a random UUID in lower case.
    public init() {
        value = UUID().uuidString.lowercased()
    }

    /// A key kept from earlier; nil unless it is 1 to 128 characters of
    /// `[A-Za-z0-9_-]`.
    public init?(_ value: String) {
        guard (1...128).contains(value.utf8.count),
              value.utf8.allSatisfy({ Self.allowed.contains($0) })
        else { return nil }
        self.value = value
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let key = IdempotencyKey(text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "not an idempotency key")
        }
        self = key
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }

    public var description: String { value }

    private static let allowed: Set<UInt8> = Set(
        Array(UInt8(ascii: "A")...UInt8(ascii: "Z")) + Array(UInt8(ascii: "a")...UInt8(ascii: "z"))
            + Array(UInt8(ascii: "0")...UInt8(ascii: "9")) + [UInt8(ascii: "_"), UInt8(ascii: "-")])
}
