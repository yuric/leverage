import Foundation
import LeverageKit

#if canImport(Darwin)
import Darwin
#endif

public enum ServerFilesError: Error, Equatable, Sendable {
    /// None of the ports from 47130 to 47139 is free on 127.0.0.1.
    case noFreePort
    /// The app bundle has no compose file at this path.
    case composeFileMissing(String)
    /// A file of the server folder could not be written; the call and errno.
    case writeFailed(path: String, errno: Int32)
}

/// What the server folder says: where it is and the port the API answers on.
public struct ServerSettings: Equatable, Sendable {
    public let folder: URL
    public let port: Int

    /// The API's address on this Mac (plain HTTP to loopback, PK-5).
    public var apiBaseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }
}

/// Writes `<support folder>/server/` (plan PK-2): the bundled compose file
/// and a `.env` with generated database passwords, a generated
/// `SECRET_KEY_BASE`, the image tag, the first free port from 47130 to
/// 47139 and `LEVERAGE_BACKUP_DIR`, the `backups` folder beside it (mode
/// 0700, HB-2). The server folder is mode 0700 and both files 0600.
///
/// The generated values and the port are made once and kept: a later start
/// reads them back (the port is by then the server's own, so it is not
/// looked at again). The compose file and the image tag follow the bundle,
/// so a rebuilt app runs its own image on the same database.
public struct ServerFiles: Sendable {
    public static let ports = 47130...47139

    /// `<support folder>/server`.
    public let folder: URL

    public init(supportFolder: URL) {
        folder = supportFolder.appendingPathComponent("server", isDirectory: true)
        backupsFolder = supportFolder.appendingPathComponent("backups", isDirectory: true)
    }

    public init(supportFolder: SupportFolder) {
        self.init(supportFolder: supportFolder.url)
    }

    /// `<support folder>/backups`: where the daily dump is written (HB-2).
    public let backupsFolder: URL

    var composeFile: URL { folder.appendingPathComponent("compose.yaml") }
    var envFile: URL { folder.appendingPathComponent(".env") }

    /// Makes the folder ready for `docker compose up` and returns what it
    /// holds. `isPortFree` is asked only when no port was chosen before.
    @discardableResult
    public func prepare(
        composeSource: URL,
        imageTag: String,
        isPortFree: (Int) -> Bool = ServerFiles.portIsFree
    ) throws -> ServerSettings {
        guard let compose = FileManager.default.contents(atPath: composeSource.path) else {
            throw ServerFilesError.composeFileMissing(composeSource.path)
        }

        let existing = readEnv()
        var values = existing
        let port: Int
        if let kept = existing["API_PORT"].flatMap(Int.init), Self.ports.contains(kept) {
            port = kept
        } else {
            guard let free = Self.ports.first(where: isPortFree) else { throw ServerFilesError.noFreePort }
            port = free
        }
        values["POSTGRES_USER"] = values["POSTGRES_USER"] ?? "leverage"
        for (name, length) in [("POSTGRES_PASSWORD", 32), ("LEVERAGE_API_DB_PASSWORD", 32), ("SECRET_KEY_BASE", 128)]
        where (values[name] ?? "").isEmpty {
            values[name] = Self.randomHex(length)
        }
        values["RAILS_ASSUME_SSL"] = values["RAILS_ASSUME_SSL"] ?? "false"
        values["RAILS_FORCE_SSL"] = values["RAILS_FORCE_SSL"] ?? "false"
        values["API_PORT"] = String(port)
        values["API_IMAGE_TAG"] = imageTag
        // Follows the support folder, like the image tag follows the bundle.
        values["LEVERAGE_BACKUP_DIR"] = backupsFolder.path

        try makeFolder()
        try makeBackupsFolder()
        if FileManager.default.contents(atPath: composeFile.path) != compose {
            try writePrivately(compose, to: composeFile)
        }
        if values != existing {
            try writePrivately(Data(Self.envText(values).utf8), to: envFile)
        }
        return ServerSettings(folder: folder, port: port)
    }

    /// Whether `.env` still holds the database owner's password. Without it
    /// `prepare` makes a new one, which a database already in Docker refuses.
    public func hasDatabasePassword() -> Bool {
        !(readEnv()["POSTGRES_PASSWORD"] ?? "").isEmpty
    }

    /// The port the server folder names, or nil before it is written.
    public func port() throws -> Int? {
        readEnv()["API_PORT"].flatMap(Int.init)
    }

    /// Whether nothing listens on 127.0.0.1 at `port`: a socket binds to it.
    public static func portIsFree(_ port: Int) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return bound == 0
    }

    // MARK: - The .env file

    /// The order the file is written in; any other name the file holds is
    /// kept after these.
    private static let order = [
        "POSTGRES_USER", "POSTGRES_PASSWORD", "LEVERAGE_API_DB_PASSWORD", "SECRET_KEY_BASE",
        "RAILS_ASSUME_SSL", "RAILS_FORCE_SSL", "API_PORT", "API_IMAGE_TAG", "LEVERAGE_BACKUP_DIR",
    ]

    private static func envText(_ values: [String: String]) -> String {
        let names = order.filter { values[$0] != nil } + values.keys.filter { !order.contains($0) }.sorted()
        return "# Written by Leverage for the server on this Mac. The values were generated\n"
            + "# on this Mac; keep this file private.\n"
            + names.map { "\($0)=\(values[$0]!)\n" }.joined()
    }

    private func readEnv() -> [String: String] {
        guard let data = FileManager.default.contents(atPath: envFile.path) else { return [:] }
        var values: [String: String] = [:]
        for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard !text.hasPrefix("#"), let equals = text.firstIndex(of: "=") else { continue }
            values[String(text[..<equals])] = String(text[text.index(after: equals)...])
        }
        return values
    }

    // MARK: - Writing

    private func makeFolder() throws {
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard chmod(folder.path, 0o700) == 0 else {
            throw ServerFilesError.writeFailed(path: folder.path, errno: errno)
        }
    }

    /// The folder the `backup` service writes its dumps into (HB-2), outside
    /// Docker so a reset of Docker does not take them. Mode 0700; a folder
    /// that exists is closed to 0700 and what is in it is left alone.
    private func makeBackupsFolder() throws {
        try FileManager.default.createDirectory(
            at: backupsFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard chmod(backupsFolder.path, 0o700) == 0 else {
            throw ServerFilesError.writeFailed(path: backupsFolder.path, errno: errno)
        }
    }

    /// Writes a file that is mode 0600 from its first byte, then moves it
    /// into place, so no other user can read it at any moment.
    private func writePrivately(_ data: Data, to url: URL) throws {
        let temporary = url.path + ".new"
        unlink(temporary)
        let descriptor = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw ServerFilesError.writeFailed(path: temporary, errno: errno) }
        var failure: Int32 = 0
        if fchmod(descriptor, 0o600) != 0 { failure = errno }
        if failure == 0 {
            failure = data.withUnsafeBytes { buffer -> Int32 in
                var offset = 0
                while offset < buffer.count {
                    let written = write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                    if written < 0 {
                        if errno == EINTR { continue }
                        return errno
                    }
                    offset += written
                }
                return 0
            }
        }
        close(descriptor)
        guard failure == 0, rename(temporary, url.path) == 0 else {
            let code = failure == 0 ? errno : failure
            unlink(temporary)
            throw ServerFilesError.writeFailed(path: url.path, errno: code)
        }
    }

    /// `length` lower-case hex digits from the system's secure generator.
    static func randomHex(_ length: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        let digits = Array("0123456789abcdef")
        return String((0..<length).map { _ in digits[Int.random(in: 0..<16, using: &generator)] })
    }
}
