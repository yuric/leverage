import Foundation
import LeverageKit

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Removes one credential's direct child of the app's private accounts
/// directory. Pin each directory before using its children.
enum AccountFolderRemoval {
    private static let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC

    static func remove(_ id: UUID, from folders: AccountFolders, confirmed: Bool) throws {
        let base = open(folders.root.deletingLastPathComponent().path, flags)
        guard base >= 0 else {
            if errno == ENOENT { return }
            throw CocoaError(.fileReadUnknown)
        }
        defer { close(base) }
        let baseInfo = try metadata(base)
        guard baseInfo.st_uid == geteuid(), baseInfo.st_mode & 0o022 == 0 else {
            throw CocoaError(.fileReadNoPermission)
        }
        let root = openat(base, "accounts", flags)
        guard root >= 0 else {
            if errno == ENOENT { return }
            throw CocoaError(.fileReadNoPermission)
        }
        defer { close(root) }
        let rootInfo = try metadata(root)
        guard rootInfo.st_uid == geteuid(), rootInfo.st_mode & 0o077 == 0 else {
            throw CocoaError(.fileReadNoPermission)
        }

        let name = id.contractString
        let account = openat(root, name, flags)
        guard account >= 0 else {
            if errno == ENOENT { return }
            throw CocoaError(.fileReadNoPermission)
        }
        defer { close(account) }
        let info = try metadata(account)
        guard info.st_uid == geteuid(), info.st_dev == rootInfo.st_dev,
              try owned(account, info: info, confirmed: confirmed) else {
            throw CocoaError(.fileWriteNoPermission)
        }
        try empty(account, device: info.st_dev)
        try unlinkDirectory(name, from: root, matching: info)
    }

    private static func metadata(_ fd: Int32) throws -> stat {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw CocoaError(.fileReadUnknown) }
        return info
    }

    private static func owned(_ account: Int32, info: stat, confirmed: Bool) throws -> Bool {
        let name = ".leverage-owned"
        var record = stat()
        guard fstatat(account, name, &record, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return confirmed && info.st_mode & 0o777 == 0o700 }
            throw CocoaError(.fileReadUnknown)
        }
        let expected = Data("\(info.st_dev):\(info.st_ino)\n".utf8)
        guard record.st_mode & S_IFMT == S_IFREG, record.st_nlink == 1,
              record.st_size == expected.count else { return false }
        let marker = openat(account, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard marker >= 0 else { throw CocoaError(.fileReadUnknown) }
        defer { close(marker) }
        let opened = try metadata(marker)
        guard opened.st_dev == record.st_dev && opened.st_ino == record.st_ino else { return false }
        return try FileHandle(fileDescriptor: marker, closeOnDealloc: false).read(upToCount: expected.count) == expected
    }

    private static func empty(_ dir: Int32, device: dev_t) throws {
        let copy = fcntl(dir, F_DUPFD_CLOEXEC, 0)
        guard copy >= 0 else { throw CocoaError(.fileReadUnknown) }
        guard let entries = fdopendir(copy) else { close(copy); throw CocoaError(.fileReadUnknown) }
        defer { closedir(entries) }
        while true {
            errno = 0
            guard let entry = readdir(entries) else {
                if errno != 0 { throw CocoaError(.fileReadUnknown) }
                return
            }
            try withUnsafeBytes(of: &entry.pointee.d_name) { bytes in
                let name = bytes.bindMemory(to: CChar.self).baseAddress!
                guard strcmp(name, ".") != 0, strcmp(name, "..") != 0 else { return }
                let child = openat(dir, name, flags)
                guard child >= 0 else {
                    if errno == ENOENT { return }
                    guard errno == ELOOP || errno == ENOTDIR else { throw CocoaError(.fileReadUnknown) }
                    if unlinkat(dir, name, 0) != 0, errno != ENOENT { throw CocoaError(.fileWriteUnknown) }
                    return
                }
                defer { close(child) }
                let info = try metadata(child)
                guard info.st_dev == device else { throw CocoaError(.fileWriteNoPermission) }
                try empty(child, device: device)
                try unlinkDirectory(name, from: dir, matching: info)
            }
        }
    }

    private static func unlinkDirectory(_ name: UnsafePointer<CChar>, from dir: Int32, matching info: stat) throws {
        var current = stat()
        guard fstatat(dir, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
              current.st_dev == info.st_dev, current.st_ino == info.st_ino,
              unlinkat(dir, name, AT_REMOVEDIR) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}
