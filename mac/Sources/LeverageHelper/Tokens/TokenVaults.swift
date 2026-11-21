import Foundation
import LeverageKit

#if canImport(Security)
import Security
#endif

/// The bundled macOS helper uses the Keychain unless explicitly set to memory (TK-1).
enum TokenVaults {
    static func make(executableURL: URL, environment: [String: String]) -> any TokenVault {
        #if canImport(Security)
        if environment[EnvironmentKeys.tokenStore] != "memory", isBundled(executableURL: executableURL) {
            return KeychainTokenVault()
        }
        #endif
        return MemoryTokenVault()
    }

    /// Matches the bundle's executable directory, including a helper launched through a symlink (TK-2).
    static func isBundled(executableURL: URL) -> Bool {
        guard executableURL.isFileURL else { return false }
        return [executableURL.standardizedFileURL, executableURL.resolvingSymlinksInPath()].contains { url in
            let executableDirectory = url.deletingLastPathComponent()
            let contents = executableDirectory.deletingLastPathComponent()
            let bundle = contents.deletingLastPathComponent()
            return executableDirectory.lastPathComponent.lowercased() == "macos"
                && contents.lastPathComponent.lowercased() == "contents"
                && bundle.pathExtension.lowercased() == "app"
        }
    }
}

#if canImport(Security)
/// One generic password per credential. Only calls on the vault open the Keychain.
final class KeychainTokenVault: TokenVault, @unchecked Sendable {
    private enum Failure: Error {
        case keychain(status: OSStatus)
        case invalidData
    }

    private let lock = NSLock()

    fileprivate init() {}

    private func query(credentialID: UUID) -> [String: Any] {
        // Use the file-based Keychain. In a user session, new items go into
        // the default Keychain, normally login. Queries use the search list.
        // Omitting the synchronizable attribute keeps operations local.
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "leverage API token",
            kSecAttrAccount as String: credentialID.contractString,
            kSecUseDataProtectionKeychain as String: false,
        ]
    }

    func store(_ token: ProviderToken, credentialID: UUID) throws {
        try lock.withLock {
            let match = query(credentialID: credentialID)
            let attributes = Self.attributes(for: token)
            let item = match.merging(attributes) { _, value in value }
            let added = SecItemAdd(item as CFDictionary, nil)
            if added == errSecSuccess { return }
            guard added == errSecDuplicateItem else { throw Failure.keychain(status: added) }

            let updated = SecItemUpdate(match as CFDictionary, attributes as CFDictionary)
            guard updated == errSecSuccess else { throw Failure.keychain(status: updated) }
        }
    }

    func read(credentialID: UUID) throws -> ProviderToken? {
        try lock.withLock {
            var match = query(credentialID: credentialID)
            match[kSecReturnAttributes as String] = true
            match[kSecReturnData as String] = true
            match[kSecMatchLimit as String] = kSecMatchLimitOne
            var found: CFTypeRef?
            let status = SecItemCopyMatching(match as CFDictionary, &found)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess else { throw Failure.keychain(status: status) }
            guard let item = found as? [String: Any] else { throw Failure.invalidData }
            return try Self.token(in: item)
        }
    }

    static func attributes(for token: ProviderToken) -> [String: Data] {
        [
            kSecValueData as String: Data(token.value.utf8),
            kSecAttrGeneric as String: Data(token.provider.rawValue.utf8),
        ]
    }

    /// An older item with no provider can still be deleted by credential ID.
    static func token(in item: [String: Any]) throws -> ProviderToken {
        guard let metadata = item[kSecAttrGeneric as String] as? Data,
              let name = String(data: metadata, encoding: .utf8),
              let provider = Provider(rawValue: name), provider.kind == .apiToken
        else { throw TokenVaultFailure.unboundProvider }
        guard let data = item[kSecValueData as String] as? Data, let token = String(data: data, encoding: .utf8)
        else { throw Failure.invalidData }
        return ProviderToken(provider: provider, value: token)
    }

    func delete(credentialID: UUID) throws {
        try lock.withLock {
            let status = SecItemDelete(query(credentialID: credentialID) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw Failure.keychain(status: status)
            }
        }
    }
}
#endif
