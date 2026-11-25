import Foundation
import LeverageTestSupport
import Testing
@testable import LeverageKit

/// Earlier versions sent their API calls through a session with a URL
/// cache, which kept bearer tokens and answers in `~/Library/Caches`. Each
/// program removes its own cache files when it starts.
@Suite("Leftover URL cache")
struct LeftoverURLCacheTests {
    let folder: TemporaryFolder
    var caches: URL { folder.url }

    init() throws {
        folder = try TemporaryFolder(prefix: "leverage-caches")
    }

    private func make(_ path: String, folder isFolder: Bool = false) throws {
        let url = caches.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if isFolder {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } else {
            try Data("made-up cache bytes".utf8).write(to: url)
        }
    }

    private func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: caches.appendingPathComponent(path).path)
    }

    @Test("the cache files of the named programs are removed, and nothing else")
    func removes() throws {
        for name in ["local.leverage.test", "LeverageHelper", "another.program"] {
            try make("\(name)/Cache.db")
            try make("\(name)/Cache.db-shm")
            try make("\(name)/Cache.db-wal")
            try make("\(name)/fsCachedData/0A1B2C3D-made-up")
            try make("\(name)/something-else.txt")
        }

        let removed = LeftoverURLCache.remove(cachesFolder: caches, names: ["local.leverage.test", "LeverageHelper"])

        #expect(removed.count == 8)
        for name in ["local.leverage.test", "LeverageHelper"] {
            for file in ["Cache.db", "Cache.db-shm", "Cache.db-wal", "fsCachedData"] {
                #expect(!exists("\(name)/\(file)"), "\(name)/\(file) is still there")
            }
            #expect(exists("\(name)/something-else.txt"))
        }
        for file in ["Cache.db", "Cache.db-shm", "Cache.db-wal", "fsCachedData/0A1B2C3D-made-up", "something-else.txt"] {
            #expect(exists("another.program/\(file)"))
        }
    }

    @Test("a program with no cache folder, or a caches folder that is missing, is no error")
    func nothingToRemove() throws {
        #expect(LeftoverURLCache.remove(cachesFolder: caches, names: ["LeverageRunner"]).isEmpty)
        let missing = caches.appendingPathComponent("no-such-folder")
        #expect(LeftoverURLCache.remove(cachesFolder: missing, names: ["LeverageRunner"]).isEmpty)
    }

    @Test("a name that is empty or leaves the caches folder is never followed", arguments: ["", ".", "..", "../outside", "a/b"])
    func unsafeNames(name: String) throws {
        try make("Cache.db")
        try make("a/b/Cache.db")
        let outside = try TemporaryFolder(prefix: "leverage-outside")
        let nested = outside.url.appendingPathComponent("caches")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: outside.url.appendingPathComponent("Cache.db"))
        try FileManager.default.createDirectory(at: outside.url.appendingPathComponent("outside"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: outside.url.appendingPathComponent("outside/Cache.db"))

        #expect(LeftoverURLCache.remove(cachesFolder: caches, names: [name]).isEmpty)
        #expect(LeftoverURLCache.remove(cachesFolder: nested, names: [name]).isEmpty)
        #expect(exists("Cache.db"))
        #expect(exists("a/b/Cache.db"))
        #expect(FileManager.default.fileExists(atPath: outside.url.appendingPathComponent("Cache.db").path))
        #expect(FileManager.default.fileExists(atPath: outside.url.appendingPathComponent("outside/Cache.db").path))
    }

    @Test("a running program names its own bundle and its own process")
    func ownNames() {
        let names = LeftoverURLCache.ownNames
        #expect(names.contains(ProcessInfo.processInfo.processName))
        #expect(!names.contains(""))
        #expect(Set(names).count == names.count)
    }
}
