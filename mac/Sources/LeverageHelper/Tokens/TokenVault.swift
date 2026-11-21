import Foundation
import LeverageKit

/// API tokens keyed only by their credential's id (TK-1).
protocol TokenVault: Sendable {
    func store(_ token: String, credentialID: UUID) throws
    func read(credentialID: UUID) throws -> String?
    func delete(credentialID: UUID) throws
}

/// The unbundled and test vault keeps validated tokens for this helper run.
final class MemoryTokenVault: TokenVault, HidesToken, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [UUID: String] = [:]

    var fieldsWithoutToken: [(String, String)] { [] }

    func store(_ token: String, credentialID: UUID) throws {
        lock.withLock { tokens[credentialID] = token }
    }

    func read(credentialID: UUID) throws -> String? {
        lock.withLock { tokens[credentialID] }
    }

    func delete(credentialID: UUID) throws {
        lock.withLock { tokens[credentialID] = nil }
    }
}
