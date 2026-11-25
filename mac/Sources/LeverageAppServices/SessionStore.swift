import Foundation
import LeverageKit

#if canImport(Security)
import Security
#endif

/// Where the owner's session token is kept between launches (plan MA-7).
public enum SessionStores {
    /// `LEVERAGE_SESSION_STORE=memory` keeps the session out of the Keychain
    /// (the smoke run); otherwise it is kept in the owner's login Keychain,
    /// under an account of its own for a support folder other than the
    /// standard one, whose server is another workspace.
    public static func make(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> any SessionStoring {
        if environment[EnvironmentKeys.sessionStore] == "memory" { return MemorySessionStore() }
        guard let suffix = SupportFolder(environment: environment, home: home).isolationSuffix else {
            return KeychainSessionStore()
        }
        return KeychainSessionStore(account: "owner-session-\(suffix)")
    }
}

/// The session in memory only: it ends with the app. For the smoke run;
/// tests use LeverageTestSupport's `FakeSessionStore` or this.
public final class MemorySessionStore: SessionStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?

    public init() {}

    public func load() throws -> String? { lock.withLock { token } }
    public func save(_ token: String) throws { lock.withLock { self.token = token } }
    public func clear() throws { lock.withLock { token = nil } }
}

public enum SessionStoreError: Error, Equatable, Sendable {
    /// A Keychain call failed with this status.
    case keychain(status: Int32)
}

/// The session in the owner's login Keychain, as one generic password: the
/// Mac side's first persistence mechanism (MA-7). Making one touches no
/// Keychain; only `load`, `save` and `clear` do. With the ad-hoc signature a
/// rebuilt app may ask the owner once to allow it; if the read fails the
/// app shows sign-in. No automated test uses it.
public final class KeychainSessionStore: SessionStoring, @unchecked Sendable {
    public let service: String
    public let account: String

    public init(service: String = "leverage", account: String = "owner-session") {
        self.service = service
        self.account = account
    }

    #if canImport(Security)
    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func load() throws -> String? {
        var search = query
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        var found: CFTypeRef?
        let status = SecItemCopyMatching(search as CFDictionary, &found)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = found as? Data else {
            throw SessionStoreError.keychain(status: status)
        }
        return String(data: data, encoding: .utf8)
    }

    public func save(_ token: String) throws {
        let data = Data(token.utf8)
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw SessionStoreError.keychain(status: update) }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        item[kSecAttrLabel as String] = "Leverage sign-in"
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw SessionStoreError.keychain(status: added) }
    }

    public func clear() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SessionStoreError.keychain(status: status)
        }
    }
    #else
    public func load() throws -> String? { nil }
    public func save(_ token: String) throws { throw SessionStoreError.keychain(status: -1) }
    public func clear() throws {}
    #endif
}
