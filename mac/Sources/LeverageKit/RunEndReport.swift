import Foundation

public struct RunEndReport: Codable, Equatable, Sendable {
    public static let formatVersion = 1

    public enum Kind: String, Codable, CaseIterable, Sendable {
        case limit
        case signedOut = "signed_out"
    }

    public let version: Int
    public let kind: Kind
    public let window: LimitWindow?
    public let resetAt: Date?
    public let taskID: UUID?
    public let reviewID: UUID?
    public let toolVersion: String?
    public let observedAt: Date

    public init(
        kind: Kind, window: LimitWindow?, resetAt: Date?, taskID: UUID?, reviewID: UUID?,
        toolVersion: String?, observedAt: Date
    ) {
        self.version = Self.formatVersion
        self.kind = kind
        self.window = window
        self.resetAt = resetAt
        self.taskID = taskID
        self.reviewID = reviewID
        self.toolVersion = toolVersion
        self.observedAt = observedAt
    }

    public func line() throws -> String { "" }

    public init(lastLineOf output: Data) throws {
        throw RunEndReportError.invalid("not built yet")
    }

    public init(line: String) throws {
        throw RunEndReportError.invalid("not built yet")
    }
}

public enum RunEndReportError: Error, Equatable, Sendable {
    case notOneLine
    case unknownKey(String)
    case invalid(String)
}
