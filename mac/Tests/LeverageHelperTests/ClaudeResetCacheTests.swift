import Foundation
import LeverageKit
import LeverageTestSupport
import Testing
@testable import LeverageHelper

struct ClaudeResetCacheTests {
    private let now = Date(timeIntervalSince1970: 1_798_761_600)
    private let entry = #"{"fetchedAtMs":1798761600000,"utilization":{"cedar_ember":[]}}"#
    private let name = "cachedUsageUtilization"

    private struct Fixture: Decodable {
        struct Meta: Decodable {
            struct Expect: Decodable { let resets: [Reset]? }
            let now: Date
            let expect: Expect
            let file_exists: Bool?
        }
        let meta: Meta
        let settings: JSONValue
    }

    @Test("each provisional settings case uses its own clock and leaves the read-only file intact")
    func cacheFixtures() throws {
        let directory = StandIns.replies.appendingPathComponent("claude")
        let fixtures = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("usage-settings-") }
        #expect(fixtures.count >= 7)
        for fixture in fixtures {
            let source = try LeverageJSON.decoder().decode(Fixture.self, from: Data(contentsOf: fixture))
            let folder = try TemporaryFolder()
            let settings = folder.path(".claude.json")
            let exists = source.meta.file_exists != false
            let bytes = try LeverageJSON.encoder().encode(source.settings)
            if exists {
                try bytes.write(to: settings)
                try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: settings.path)
            }
            #expect(ClaudeResetCache.read(accountFolder: folder.url, now: source.meta.now) == source.meta.expect.resets,
                    "\(fixture.lastPathComponent)")
            if exists {
                #expect(try Data(contentsOf: settings) == bytes)
            } else {
                #expect(!FileManager.default.fileExists(atPath: settings.path))
            }
        }
    }

    @Test("the top-level cache is read without mistaking quoted text, braces or nested keys for a field")
    func topLevelOnly() throws {
        let nested = #""sample":[{"cachedUsageUtilization":null,"text":"a quote \" and }, ]"},true,null,-7.4e+2]"#
        let id = "SYNTHETIC-ACCOUNT-DETAIL"
        let secret = "SYNTHETIC-KEY-MATERIAL"
        let json = #"{\#(nested),"accountId":"\#(id)","cached\u0055sageUtilization":\#(entry),"other":"\#(secret)"}"#
        let resets: [Reset]? = ClaudeResetCache.read(data: Data(json.utf8), now: now)
        let safe = try #require(resets)
        #expect(safe == [])
        let output = String(decoding: try LeverageJSON.encoder().encode(safe), as: UTF8.self)
        #expect(!output.contains(id))
        #expect(!output.contains(secret))
        #expect(ClaudeResetCache.read(data: Data(#"{"child":{"\#(name)":\#(entry)}}"#.utf8), now: now) == nil)
    }

    @Test("a malformed or ambiguous settings file never supplies a count")
    func malformed() {
        for value in [
            #"{"\#(name)":\#(entry),"broken":]}"#,
            #"{"\#(name)":\#(entry),"\#(name)":null}"#,
            #"{"\#(name)":\#(entry)} trailing"#,
            #"{"\#(name)":\#(entry),}"#,
            #"{"unknown":bad,"\#(name)":\#(entry)}"#,
            #"{"\#(name)":{"fetchedAtMs":true,"utilization":{"cedar_ember":[]}}}"#,
            #"{"\#(name)":{"fetchedAtMs":1798761600000,"utilization":{}}}"#,
            #"{"\#(name)":{"fetchedAtMs":1798761600000,"utilization":{"cedar_ember":0}}}"#,
            #"{"\#(name)":{"fetchedAtMs":1798761600000,"utilization":{"cedar_ember":{"sample":1}}}}"#,
        ] {
            #expect(ClaudeResetCache.read(data: Data(value.utf8), now: now) == nil)
        }
    }

    @Test("ten minutes is inclusive and a fetch after the read cannot count")
    func clockBounds() {
        let file = Data(#"{"\#(name)":\#(entry)}"#.utf8)
        #expect(ClaudeResetCache.read(data: file, now: now.addingTimeInterval(600)) == [])
        #expect(ClaudeResetCache.read(data: file, now: now.addingTimeInterval(600.001)) == nil)
        #expect(ClaudeResetCache.read(data: file, now: now.addingTimeInterval(-0.001)) == nil)
    }

    @Test("oversize settings and oversize cache entries are independently refused")
    func sizeBounds() throws {
        let account = try TemporaryFolder()
        let settings = account.path(".claude.json")
        let largeFile = #"{"\#(name)":\#(entry),"unused":"\#(String(repeating: "x", count: 6 * 1024 * 1024))"}"#
        let largeEntry = #"{"\#(name)":{"padding":"\#(String(repeating: "x", count: 65 * 1024))",\#(entry.dropFirst())}"#
        for json in [largeFile, largeEntry] {
            let bytes = Data(json.utf8)
            try bytes.write(to: settings)
            #expect(ClaudeResetCache.read(data: bytes, now: now) == nil)
            #expect(ClaudeResetCache.read(accountFolder: account.url, now: now) == nil)
        }
    }

    @Test("a link cannot redirect a cache read to another account")
    func rejectsLinks() throws {
        let root = try TemporaryFolder()
        let account = try root.folder("account")
        let other = try root.folder("other")
        let real = other.appendingPathComponent(".claude.json")
        try Data(#"{"\#(name)":\#(entry)}"#.utf8).write(to: real)
        try FileManager.default.createSymbolicLink(at: account.appendingPathComponent(".claude.json"),
                                                   withDestinationURL: real)
        #expect(ClaudeResetCache.read(accountFolder: account, now: now) == nil)
        let alias = root.path("linked-account")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: other)
        #expect(ClaudeResetCache.read(accountFolder: alias, now: now) == nil)
    }
}
