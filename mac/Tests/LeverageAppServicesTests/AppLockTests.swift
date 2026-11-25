import Foundation
import LeverageKit
import LeverageTestSupport
import Testing

@testable import LeverageAppServices

@Suite("AppLock")
struct AppLockTests {
    @Test("a second lock on one support folder fails and names the first holder")
    func secondLockFails() throws {
        let folder = try TemporaryFolder(prefix: "leverage-app-lock")
        let support = folder.url.appendingPathComponent("support")
        let first = try AppLock(supportFolder: support)
        #expect(FileManager.default.fileExists(atPath: support.appendingPathComponent("app.lock").path))

        #expect(throws: AppLockError.heldByAnotherCopy(processID: ProcessInfo.processInfo.processIdentifier)) {
            _ = try AppLock(supportFolder: support)
        }
        withExtendedLifetime(first) {}
    }

    @Test("once released, the folder can be locked again")
    func releaseThenLockAgain() throws {
        let folder = try TemporaryFolder(prefix: "leverage-app-lock")
        let support = folder.url.appendingPathComponent("support")
        let first = try AppLock(supportFolder: support)
        first.release()
        let second = try AppLock(supportFolder: support)
        withExtendedLifetime(second) {}
    }

    @Test("two support folders lock apart")
    func twoFolders() throws {
        let folder = try TemporaryFolder(prefix: "leverage-app-lock")
        let one = try AppLock(supportFolder: folder.url.appendingPathComponent("one"))
        let two = try AppLock(supportFolder: folder.url.appendingPathComponent("two"))
        withExtendedLifetime((one, two)) {}
    }
}

@Suite("SessionStore")
struct SessionStoreTests {
    @Test("the memory store keeps, gives back and forgets a session")
    func memoryStore() throws {
        let store = MemorySessionStore()
        #expect(try store.load() == nil)
        try store.save("lvo_made-up-session")
        #expect(try store.load() == "lvo_made-up-session")
        try store.clear()
        #expect(try store.load() == nil)
    }

    @Test("LEVERAGE_SESSION_STORE=memory keeps the session out of the Keychain")
    func choosesStore() {
        #expect(SessionStores.make(environment: ["LEVERAGE_SESSION_STORE": "memory"]) is MemorySessionStore)
        // Only the type is looked at: making the Keychain store touches no
        // Keychain (MA-7: no automated test reads or writes it).
        #expect(SessionStores.make(environment: [:]) is KeychainSessionStore)
    }

    @Test("a support folder of its own keeps its session under a Keychain account of its own")
    func storePerSupportFolder() throws {
        let home = URL(fileURLWithPath: "/Users/made-up", isDirectory: true)
        let standard = try #require(SessionStores.make(environment: [:], home: home) as? KeychainSessionStore)
        #expect(standard.account == "owner-session")
        #expect(standard.service == "leverage")
        let environment = ["LEVERAGE_SUPPORT_DIR": "/tmp/a"]
        let other = try #require(SessionStores.make(environment: environment, home: home) as? KeychainSessionStore)
        let suffix = try #require(SupportFolder(environment: environment, home: home).isolationSuffix)
        #expect(other.account == "owner-session-\(suffix)")
        #expect(SessionStores.make(environment: environment.merging(["LEVERAGE_SESSION_STORE": "memory"]) { $1 }, home: home)
            is MemorySessionStore)
    }
}
