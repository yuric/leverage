import Foundation
import LeverageKit
import LeverageTestSupport
import Testing

@testable import LeverageAppServices

@Suite("ServerFiles")
struct ServerFilesTests {
    private func values(in env: URL) throws -> [String: String] {
        let text = try String(contentsOf: env, encoding: .utf8)
        var found: [String: String] = [:]
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            if let equals = line.firstIndex(of: "=") {
                found[String(line[..<equals])] = String(line[line.index(after: equals)...])
            }
        }
        return found
    }

    private func isHex(_ text: String?, length: Int) -> Bool {
        guard let text, text.count == length else { return false }
        return text.allSatisfy { "0123456789abcdef".contains($0) }
    }

    @Test("writes the compose file and a .env of generated values, mode 0600, in a folder only the owner opens")
    func writesTheFolder() throws {
        let fake = try FakeDocker()
        let files = ServerFiles(supportFolder: fake.supportFolder)
        let settings = try files.prepare(composeSource: fake.composeSource, imageTag: "0.1.0", isPortFree: { _ in true })

        let server = fake.supportFolder.appendingPathComponent("server")
        #expect(settings.folder.path == server.path)
        #expect(settings.port == 47130)
        #expect(settings.apiBaseURL.absoluteString == "http://127.0.0.1:47130")
        #expect(mode(of: server) == 0o700)
        #expect(mode(of: server.appendingPathComponent(".env")) == 0o600)
        #expect(mode(of: server.appendingPathComponent("compose.yaml")) == 0o600)
        #expect(try Data(contentsOf: server.appendingPathComponent("compose.yaml"))
            == Data(contentsOf: fake.composeSource))

        let env = try values(in: server.appendingPathComponent(".env"))
        #expect(env["POSTGRES_USER"] == "leverage")
        #expect(isHex(env["POSTGRES_PASSWORD"], length: 32))
        #expect(isHex(env["LEVERAGE_API_DB_PASSWORD"], length: 32))
        #expect(isHex(env["SECRET_KEY_BASE"], length: 128))
        #expect(env["POSTGRES_PASSWORD"] != env["LEVERAGE_API_DB_PASSWORD"])
        #expect(env["RAILS_ASSUME_SSL"] == "false")
        #expect(env["RAILS_FORCE_SSL"] == "false")
        #expect(env["API_PORT"] == "47130")
        #expect(env["API_IMAGE_TAG"] == "0.1.0")
        #expect(try files.port() == 47130)
    }

    @Test("takes the first free port from 47130 to 47139")
    func firstFreePort() throws {
        let fake = try FakeDocker()
        let asked = Locked<[Int]>([])
        let settings = try ServerFiles(supportFolder: fake.supportFolder).prepare(
            composeSource: fake.composeSource, imageTag: "0.1.0",
            isPortFree: { port in asked.update { $0.append(port) }; return port >= 47132 })
        #expect(settings.port == 47132)
        #expect(asked.value == [47130, 47131, 47132])
    }

    @Test("fails when none of the ten ports is free, and writes no .env")
    func noFreePort() throws {
        let fake = try FakeDocker()
        let asked = Locked<[Int]>([])
        let files = ServerFiles(supportFolder: fake.supportFolder)
        #expect(throws: ServerFilesError.noFreePort) {
            try files.prepare(
                composeSource: fake.composeSource, imageTag: "0.1.0",
                isPortFree: { port in asked.update { $0.append(port) }; return false })
        }
        #expect(asked.value == Array(47130...47139))
        #expect(!FileManager.default.fileExists(
            atPath: fake.supportFolder.appendingPathComponent("server/.env").path))
    }

    @Test("is written once: a second start keeps the passwords and the port, and follows the bundle's image tag")
    func writtenOnce() throws {
        let fake = try FakeDocker()
        let files = ServerFiles(supportFolder: fake.supportFolder)
        let env = fake.supportFolder.appendingPathComponent("server/.env")
        _ = try files.prepare(composeSource: fake.composeSource, imageTag: "0.1.0", isPortFree: { $0 == 47135 })
        let first = try values(in: env)

        // The port is now the server's own, so it is no longer free; it is
        // not looked at again.
        let second = try files.prepare(
            composeSource: fake.composeSource, imageTag: "0.2.0", isPortFree: { _ in false })
        let again = try values(in: env)

        #expect(second.port == 47135)
        #expect(again["POSTGRES_PASSWORD"] == first["POSTGRES_PASSWORD"])
        #expect(again["LEVERAGE_API_DB_PASSWORD"] == first["LEVERAGE_API_DB_PASSWORD"])
        #expect(again["SECRET_KEY_BASE"] == first["SECRET_KEY_BASE"])
        #expect(again["API_PORT"] == "47135")
        #expect(again["API_IMAGE_TAG"] == "0.2.0")
        #expect(mode(of: env) == 0o600)
    }

    @Test("two support folders get different generated values")
    func valuesAreGenerated() throws {
        let fake = try FakeDocker()
        let one = try ServerFiles(supportFolder: fake.root.appendingPathComponent("one"))
            .prepare(composeSource: fake.composeSource, imageTag: "t", isPortFree: { _ in true })
        let two = try ServerFiles(supportFolder: fake.root.appendingPathComponent("two"))
            .prepare(composeSource: fake.composeSource, imageTag: "t", isPortFree: { _ in true })
        let first = try values(in: one.folder.appendingPathComponent(".env"))
        let second = try values(in: two.folder.appendingPathComponent(".env"))
        #expect(first["SECRET_KEY_BASE"] != second["SECRET_KEY_BASE"])
        #expect(first["POSTGRES_PASSWORD"] != second["POSTGRES_PASSWORD"])
    }

    @Test("fails when the bundle has no compose file")
    func missingComposeFile() throws {
        let fake = try FakeDocker()
        let missing = fake.root.appendingPathComponent("bundle/nothing.yaml")
        #expect(throws: ServerFilesError.composeFileMissing(missing.path)) {
            try ServerFiles(supportFolder: fake.supportFolder)
                .prepare(composeSource: missing, imageTag: "t", isPortFree: { _ in true })
        }
    }

    @Test("a port this Mac is listening on is not free")
    func portProbe() throws {
        let listener = try #require(TestListener())
        #expect(ServerFiles.portIsFree(listener.port) == false)
    }
}

#if canImport(Darwin)
import Darwin

/// A socket listening on 127.0.0.1 on a port the system picks.
final class TestListener {
    let descriptor: Int32
    let port: Int

    init?() {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 1) == 0 else { close(fd); return nil }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard named == 0 else { close(fd); return nil }
        descriptor = fd
        port = Int(UInt16(bigEndian: address.sin_port))
    }

    deinit { close(descriptor) }
}
#endif
