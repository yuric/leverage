import Foundation
import LeverageKit

#if canImport(Darwin)
import Darwin
#endif

public enum AppLockError: Error, Equatable, Sendable {
    /// Another copy of the app holds the support folder; its process id,
    /// when the lock file names one, so the app can bring it to the front.
    case heldByAnotherCopy(processID: Int32?)
    /// The lock file could not be opened; the path and errno.
    case unavailable(path: String, errno: Int32)
}

/// One running app per support folder (plan PK-8): an exclusive lock on
/// `<support folder>/app.lock`, held until `release()` or until the value
/// is gone (and by the system until the process ends). The holder writes
/// its process id into the file.
public final class AppLock: @unchecked Sendable {
    public let file: URL
    private let lock = NSLock()
    private var descriptor: Int32

    public init(supportFolder: URL) throws {
        try? FileManager.default.createDirectory(
            at: supportFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        file = supportFolder.appendingPathComponent("app.lock")
        let opened = open(file.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard opened >= 0 else { throw AppLockError.unavailable(path: file.path, errno: errno) }
        guard flock(opened, LOCK_EX | LOCK_NB) == 0 else {
            let failure = errno
            let holder = Self.processID(in: opened)
            close(opened)
            if failure == EWOULDBLOCK { throw AppLockError.heldByAnotherCopy(processID: holder) }
            throw AppLockError.unavailable(path: file.path, errno: failure)
        }
        descriptor = opened
        let text = "\(getpid())\n"
        _ = ftruncate(opened, 0)
        _ = text.withCString { pwrite(opened, $0, strlen($0), 0) }
    }

    public convenience init(supportFolder: SupportFolder) throws {
        try self.init(supportFolder: supportFolder.url)
    }

    deinit { release() }

    /// Gives the folder up. The file stays; only the lock goes.
    public func release() {
        lock.withLock {
            guard descriptor >= 0 else { return }
            flock(descriptor, LOCK_UN)
            close(descriptor)
            descriptor = -1
        }
    }

    private static func processID(in descriptor: Int32) -> Int32? {
        var buffer = [UInt8](repeating: 0, count: 32)
        let count = pread(descriptor, &buffer, buffer.count - 1, 0)
        guard count > 0 else { return nil }
        let text = String(decoding: buffer[0..<count], as: UTF8.self)
        return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
