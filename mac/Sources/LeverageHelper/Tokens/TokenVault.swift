import Foundation
import LeverageKit

/// The provider and token received together on the local channel.
struct ProviderToken: Sendable, Equatable, HidesToken {
    let provider: Provider
    let value: String

    var fieldsWithoutToken: [(String, String)] { [("provider", provider.rawValue)] }
}

enum TokenVaultFailure: Error {
    case unboundProvider

    static func checkFailure(for error: any Error) -> HelperCheckFailure {
        error is TokenVaultFailure ? .providerMismatch : .tokenStoreUnavailable
    }
}

/// API tokens indexed by credential ID with their locally chosen provider (TK-1).
protocol TokenVault: Sendable {
    func store(_ token: ProviderToken, credentialID: UUID) throws
    func read(credentialID: UUID) throws -> ProviderToken?
    func delete(credentialID: UUID) throws
}

/// The unbundled and test vault keeps validated tokens for this helper run.
final class MemoryTokenVault: TokenVault, HidesToken, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [UUID: ProviderToken] = [:]

    var fieldsWithoutToken: [(String, String)] { [] }

    func store(_ token: ProviderToken, credentialID: UUID) throws {
        lock.withLock { tokens[credentialID] = token }
    }

    func read(credentialID: UUID) throws -> ProviderToken? {
        lock.withLock { tokens[credentialID] }
    }

    func delete(credentialID: UUID) throws {
        lock.withLock { tokens[credentialID] = nil }
    }
}
