import Foundation

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// The app tries to record a confirmed Remove before sending forget. The
/// helper clears the record after deleting the token and removing or
/// leaving an unverified settings folder.
public struct PendingCredentialRemovals: Sendable {
    private let support: URL
    private let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC

    public init(supportFolder: URL) { support = supportFolder }

    public func insert(_ id: UUID) throws {
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try withDirectory(create: true) { dir in
            let file = openat(dir, id.contractString, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
            if file >= 0 { close(file); return }
            guard errno == EEXIST, try contains(id, in: dir) else { throw CocoaError(.fileWriteUnknown) }
        }
    }

    public func pending() throws -> [UUID] {
        try withDirectory(create: false) { dir in
            let copy = fcntl(dir, F_DUPFD_CLOEXEC, 0)
            guard copy >= 0 else { throw CocoaError(.fileReadUnknown) }
            guard let entries = fdopendir(copy) else { close(copy); throw CocoaError(.fileReadUnknown) }
            defer { closedir(entries) }
            var ids: [UUID] = []
            while true {
                errno = 0
                guard let entry = readdir(entries) else {
                    if errno != 0 { throw CocoaError(.fileReadUnknown) }
                    return ids
                }
                let name = withUnsafeBytes(of: &entry.pointee.d_name) {
                    String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
                }
                if let id = UUID(uuidString: name), name == id.contractString, try contains(id, in: dir) {
                    ids.append(id)
                }
            }
        } ?? []
    }

    public func contains(_ id: UUID) throws -> Bool {
        try withDirectory(create: false) { try contains(id, in: $0) } ?? false
    }

    public func complete(_ id: UUID) throws {
        try withDirectory(create: false) { dir in
            if unlinkat(dir, id.contractString, 0) != 0, errno != ENOENT { throw CocoaError(.fileWriteUnknown) }
        }
    }

    private func contains(_ id: UUID, in dir: Int32) throws -> Bool {
        var info = stat()
        guard fstatat(dir, id.contractString, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return false }
            throw CocoaError(.fileReadUnknown)
        }
        return info.st_mode & S_IFMT == S_IFREG && info.st_uid == geteuid() &&
            info.st_size == 0 && info.st_nlink == 1
    }

    @discardableResult
    private func withDirectory<T>(create: Bool, _ body: (Int32) throws -> T) throws -> T? {
        let base = open(support.path, flags)
        guard base >= 0 else {
            if !create && errno == ENOENT { return nil }
            throw CocoaError(.fileReadUnknown)
        }
        defer { close(base) }
        var info = stat()
        guard fstat(base, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o022 == 0 else {
            throw CocoaError(.fileReadNoPermission)
        }
        let name = "pending-removals"
        if create, mkdirat(base, name, 0o700) != 0, errno != EEXIST { throw CocoaError(.fileWriteUnknown) }
        let dir = openat(base, name, flags)
        guard dir >= 0 else {
            if !create && errno == ENOENT { return nil }
            throw CocoaError(.fileReadUnknown)
        }
        defer { close(dir) }
        guard fstat(dir, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else {
            throw CocoaError(.fileReadNoPermission)
        }
        return try body(dir)
    }
}
