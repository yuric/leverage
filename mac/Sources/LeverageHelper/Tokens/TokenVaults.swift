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

    func store(_ token: String, credentialID: UUID) throws {
        try lock.withLock {
            let match = query(credentialID: credentialID)
            let data = Data(token.utf8)
            var item = match
            item[kSecValueData as String] = data
            let added = SecItemAdd(item as CFDictionary, nil)
            if added == errSecSuccess { return }
            guard added == errSecDuplicateItem else { throw Failure.keychain(status: added) }

            let changes = [kSecValueData as String: data]
            let updated = SecItemUpdate(match as CFDictionary, changes as CFDictionary)
            guard updated == errSecSuccess else { throw Failure.keychain(status: updated) }
        }
    }

    func read(credentialID: UUID) throws -> String? {
        try lock.withLock {
            var match = query(credentialID: credentialID)
            match[kSecReturnData as String] = true
            match[kSecMatchLimit as String] = kSecMatchLimitOne
            var found: CFTypeRef?
            let status = SecItemCopyMatching(match as CFDictionary, &found)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess else { throw Failure.keychain(status: status) }
            guard let data = found as? Data, let token = String(data: data, encoding: .utf8) else {
                throw Failure.invalidData
            }
            return token
        }
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
