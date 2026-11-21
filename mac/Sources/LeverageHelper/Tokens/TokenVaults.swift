import Foundation

enum TokenVaults {
    static func make(executableURL: URL, environment: [String: String]) -> any TokenVault {
        MemoryTokenVault()
    }

    static func isBundled(executableURL: URL) -> Bool { false }
}

#if canImport(Security)
struct KeychainTokenVault: TokenVault {
    func store(_ token: String, credentialID: UUID) throws {}
    func read(credentialID: UUID) throws -> String? { nil }
    func delete(credentialID: UUID) throws {}
}
#endif
