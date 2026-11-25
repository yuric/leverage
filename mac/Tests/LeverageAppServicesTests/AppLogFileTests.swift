import Foundation
import LeverageKit
import LeverageTestSupport
import Testing

@testable import LeverageAppServices

/// The app's own log lines, kept in `<support folder>/logs/app.log`.
@Suite("AppLogFile")
struct AppLogFileTests {
    private func mode(_ url: URL) throws -> Int {
        try (FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    @Test("each line is appended to logs/app.log, owner-only, and still reaches standard error")
    func appends() throws {
        let folder = try TemporaryFolder(prefix: "leverage-app-log")
        let forwarded = Locked<[String]>([])
        let file = AppLogFile(supportFolder: folder.url, alsoWrite: { line in forwarded.update { $0.append(line) } })
        let log = Log(component: "app", write: file.write)
        log.error("the first made-up line")
        log.info("the second made-up line")
        let written = try String(contentsOf: file.url, encoding: .utf8)
        #expect(written.components(separatedBy: "\n").filter { !$0.isEmpty }.count == 2)
        #expect(written.contains("app error: the first made-up line"))
        #expect(written.contains("app info: the second made-up line"))
        #expect(forwarded.value.count == 2)
        #expect(try mode(file.url) == 0o600)
        #expect(try mode(folder.url.appendingPathComponent("logs")) == 0o700)
    }

    @Test("a log past its limit is replaced, keeping one older file")
    func replacesPastLimit() throws {
        let folder = try TemporaryFolder(prefix: "leverage-app-log")
        let file = AppLogFile(supportFolder: folder.url, limitBytes: 64, alsoWrite: { _ in })
        file.write(String(repeating: "x", count: 100) + "\n")
        file.write("after the limit\n")
        #expect(try String(contentsOf: file.url, encoding: .utf8) == "after the limit\n")
        let older = folder.url.appendingPathComponent("logs/app.log.1")
        #expect(try String(contentsOf: older, encoding: .utf8).hasPrefix("xxxx"))
    }

    @Test("a folder that cannot be written still leaves the line on standard error")
    func unwritableFolder() throws {
        let folder = try TemporaryFolder(prefix: "leverage-app-log")
        let blocked = folder.url.appendingPathComponent("blocked")
        try Data().write(to: blocked)
        let forwarded = Locked<[String]>([])
        let file = AppLogFile(supportFolder: blocked, alsoWrite: { line in forwarded.update { $0.append(line) } })
        file.write("a made-up line\n")
        #expect(forwarded.value == ["a made-up line\n"])
        #expect(!FileManager.default.fileExists(atPath: file.url.path))
    }
}
