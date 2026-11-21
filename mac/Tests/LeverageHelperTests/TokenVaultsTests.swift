import Foundation
import LeverageKit
import Testing
#if canImport(Security)
import Security
#endif

@testable import LeverageHelper

@Suite("API token vaults")
struct TokenVaultsTests {
    private let bundleExecutable = URL(fileURLWithPath: "/Example/Leverage.app/Contents/MacOS/LeverageHelper")

    @Test("the test program uses memory even without the override")
    func testExecutableUsesMemory() throws {
        let executableURL = try #require(Bundle.main.executableURL)
        #expect(TokenVaults.make(executableURL: executableURL, environment: [:]) is MemoryTokenVault)
    }

    @Test("a bundled helper also uses memory when the override is set")
    func bundleUsesMemoryWithOverride() {
        let vault = TokenVaults.make(
            executableURL: bundleExecutable, environment: [EnvironmentKeys.tokenStore: "memory"])
        #expect(vault is MemoryTokenVault)
    }

    @Test("the bundled helper selects the platform vault without opening it")
    func bundleDefault() {
        let vault = TokenVaults.make(executableURL: bundleExecutable, environment: [:])
        #if canImport(Security)
        #expect(vault is KeychainTokenVault)
        #else
        #expect(vault is MemoryTokenVault)
        #endif
    }

    @Test("the app-bundle guard identifies the bundle's executable directory")
    func bundleGuard() {
        #expect(TokenVaults.isBundled(executableURL: bundleExecutable))
        let executableNamedLikeABundle = URL(fileURLWithPath: "/Example/Leverage.app")
        #expect(!TokenVaults.isBundled(executableURL: executableNamedLikeABundle))
        let nonBundle = URL(fileURLWithPath: "/Example/Leverage.app-copy/Contents/MacOS/LeverageHelper")
        #expect(!TokenVaults.isBundled(executableURL: nonBundle))
        let testRunner = URL(fileURLWithPath: "/Example/Xcode.app/Contents/Developer/bin/swiftpm-testing-helper")
        #expect(!TokenVaults.isBundled(executableURL: testRunner))
    }

    #if canImport(Security)
    @Test("a Keychain record needs the provider metadata written alongside its value")
    func storedProvider() throws {
        let sample = ProviderToken(provider: .grokApi, value: "LVRG-TOKEN-000000000707")
        var item = KeychainTokenVault.attributes(for: sample)
        #expect(item[kSecAttrGeneric as String] == Data(sample.provider.rawValue.utf8))
        let matches = try KeychainTokenVault.token(in: item) == sample
        #expect(matches)
        item[kSecAttrGeneric as String] = nil
        #expect(throws: TokenVaultFailure.unboundProvider) { try KeychainTokenVault.token(in: item) }
        item[kSecAttrGeneric as String] = Data(Provider.codex.rawValue.utf8)
        #expect(throws: TokenVaultFailure.unboundProvider) { try KeychainTokenVault.token(in: item) }
    }
    #endif

    @Test("memory vault stores, replaces and deletes by credential ID")
    func memoryVault() throws {
        let vault = MemoryTokenVault()
        let first = UUID()
        let second = UUID()
        let token = ProviderToken(provider: .openrouter, value: "LVRG-TOKEN-bf493a02950e")
        let newToken = ProviderToken(provider: .geminiApi, value: "LVRG-TOKEN-beef310cd75a")

        try vault.store(token, credentialID: first)
        try vault.store(token, credentialID: second)
        let firstStoreSucceeded = try vault.read(credentialID: first) == token
        #expect(firstStoreSucceeded)
        try vault.store(newToken, credentialID: first)
        let replacementSucceeded = try vault.read(credentialID: first) == newToken
        #expect(replacementSucceeded)
        try vault.delete(credentialID: first)
        try vault.delete(credentialID: first)
        let firstIsGone = try vault.read(credentialID: first) == nil
        let secondIsPresent = try vault.read(credentialID: second) == token
        #expect(firstIsGone)
        #expect(secondIsPresent)
    }
}

/// Models a Keychain that refuses access without calling the Security API.
struct LockedTestVault: TokenVault {
    func store(_ token: ProviderToken, credentialID: UUID) throws { throw CocoaError(.fileWriteNoPermission) }
    func read(credentialID: UUID) throws -> ProviderToken? { throw CocoaError(.fileReadNoPermission) }
    func delete(credentialID: UUID) throws { throw CocoaError(.fileWriteNoPermission) }
}
