import Foundation

protocol TokenVault: Sendable {
    func store(_ token: String, credentialID: UUID) throws
    func read(credentialID: UUID) throws -> String?
    func delete(credentialID: UUID) throws
}

final class MemoryTokenVault: TokenVault {
    func store(_ token: String, credentialID: UUID) throws {}
    func read(credentialID: UUID) throws -> String? { nil }
    func delete(credentialID: UUID) throws {}
}
