import Foundation
import LeverageKit
import LeverageTestSupport
import Testing

@testable import LeverageAppServices

@Suite("InboxCursorStore")
struct InboxCursorStoreTests {
    private func file(in folder: TemporaryFolder) -> URL {
        folder.path("inbox-cursor")
    }

    @Test("a number written is read back by a new store on the same folder")
    func survivesTheApp() throws {
        let folder = try TemporaryFolder(prefix: "leverage-cursor")
        try InboxCursorStore(folder: folder.url).save(41)
        #expect(InboxCursorStore(folder: folder.url).load() == 41)
        try InboxCursorStore(folder: folder.url).save(7_000_000_000)
        #expect(InboxCursorStore(folder: folder.url).load() == 7_000_000_000)
    }

    @Test("a folder with nothing in it reads as 0, and so does a folder that is not there")
    func missingReadsAsZero() throws {
        let folder = try TemporaryFolder(prefix: "leverage-cursor")
        #expect(InboxCursorStore(folder: folder.url).load() == 0)
        #expect(InboxCursorStore(folder: folder.path("not", "there")).load() == 0)
    }

    @Test("a file that cannot be read, or holds no number, reads as 0")
    func unreadableReadsAsZero() throws {
        let folder = try TemporaryFolder(prefix: "leverage-cursor")
        let store = InboxCursorStore(folder: folder.url)
        try store.save(12)

        try Data("not a number\n".utf8).write(to: file(in: folder))
        #expect(store.load() == 0)
        try Data("-5\n".utf8).write(to: file(in: folder))
        #expect(store.load() == 0)
        try Data().write(to: file(in: folder))
        #expect(store.load() == 0)

        try store.save(12)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file(in: folder).path)
        #expect(store.load() == 0)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file(in: folder).path)
        #expect(store.load() == 12)

        // A folder where the file should be is unreadable as a number too.
        try FileManager.default.removeItem(at: file(in: folder))
        try FileManager.default.createDirectory(at: file(in: folder), withIntermediateDirectories: true)
        #expect(store.load() == 0)
    }

    @Test("the file is mode 0600, and stays so when it is written again")
    func fileMode() throws {
        let folder = try TemporaryFolder(prefix: "leverage-cursor")
        let store = InboxCursorStore(folder: folder.url)
        try store.save(3)
        #expect(mode(of: file(in: folder)) == 0o600)
        try store.save(4)
        #expect(mode(of: file(in: folder)) == 0o600)
        #expect(store.load() == 4)
    }

    @Test("a folder that is not there yet is made, closed to other users")
    func makesTheFolder() throws {
        let folder = try TemporaryFolder(prefix: "leverage-cursor")
        let support = folder.path("support")
        try InboxCursorStore(folder: support).save(9)
        #expect(mode(of: support) == 0o700)
        #expect(InboxCursorStore(folder: support).load() == 9)
    }

    @Test("a save that cannot be written throws, and keeps the number that was there")
    func failedSaveThrows() throws {
        let folder = try TemporaryFolder(prefix: "leverage-cursor")
        let store = InboxCursorStore(folder: folder.url)
        try store.save(5)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.url.path) }
        #expect(throws: (any Error).self) { try store.save(6) }
        #expect(store.load() == 5)
    }

    @Test("it holds only the number, nothing else")
    func holdsOnlyTheNumber() throws {
        let folder = try TemporaryFolder(prefix: "leverage-cursor")
        try InboxCursorStore(folder: folder.url).save(15)
        let files = textOfEveryFile(under: folder.url)
        #expect(files.count == 1)
        #expect(files.values.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "15")
    }
}
