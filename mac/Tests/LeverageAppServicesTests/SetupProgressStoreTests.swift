import Foundation
import LeverageKit
import LeverageTestSupport
import Testing

@testable import LeverageAppServices

@Suite("SetupProgressStore")
struct SetupProgressStoreTests {
    private func file(in folder: TemporaryFolder) -> URL {
        folder.path(SetupProgressStore.fileName)
    }

    @Test("a choice written is read back by a new store on the same folder")
    func survivesTheApp() throws {
        let folder = try TemporaryFolder(prefix: "leverage-setup")
        for choice in SetupChoice.allCases {
            try SetupProgressStore(folder: folder.url).save(choice)
            #expect(SetupProgressStore(folder: folder.url).load() == choice)
        }
    }

    @Test("a folder with nothing in it reads as not chosen, and so does a folder that is not there")
    func missingReadsAsNotChosen() throws {
        let folder = try TemporaryFolder(prefix: "leverage-setup")
        #expect(SetupProgressStore(folder: folder.url).load() == .notChosen)
        #expect(SetupProgressStore(folder: folder.path("not", "there")).load() == .notChosen)
    }

    @Test("a file that holds anything but a choice reads as not chosen")
    func unreadableReadsAsNotChosen() throws {
        let folder = try TemporaryFolder(prefix: "leverage-setup")
        let store = SetupProgressStore(folder: folder.url)
        try store.save(.skipped)
        try Data("later\n".utf8).write(to: file(in: folder))
        #expect(store.load() == .notChosen)
        try Data().write(to: file(in: folder))
        #expect(store.load() == .notChosen)
    }

    @Test("the file is made in a folder that was not there, and only the owner can read it")
    func makesTheFolderAndKeepsTheFilePrivate() throws {
        let folder = try TemporaryFolder(prefix: "leverage-setup")
        let nested = folder.path("support")
        try SetupProgressStore(folder: nested).save(.finished)
        let path = nested.appendingPathComponent(SetupProgressStore.fileName).path
        let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
        #expect(String(decoding: try #require(FileManager.default.contents(atPath: path)), as: UTF8.self) == "finished\n")
    }

    @Test("a choice that cannot be written throws and keeps the one that was there")
    func failedWriteKeepsTheOldChoice() throws {
        let folder = try TemporaryFolder(prefix: "leverage-setup")
        let store = SetupProgressStore(folder: folder.url)
        try store.save(.started)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.url.path) }
        #expect(throws: SetupProgressStoreError.self) { try store.save(.finished) }
        #expect(store.load() == .started)
    }
}
