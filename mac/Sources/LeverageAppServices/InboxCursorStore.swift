import Foundation
import LeverageKit

#if canImport(Darwin)
import Darwin
#endif

public enum InboxCursorStoreError: Error, Equatable, Sendable {
    /// The cursor file could not be written; the path and errno.
    case writeFailed(path: String, errno: Int32)
}

/// `InboxCursorStoring` on one small file in the support folder, mode 0600:
/// the last `inbox.opened` `seq` announced (plan HM-29). No secret. The file
/// holds the number as text and nothing else, so it outlives the app: a new
/// store on the same folder reads what the last one wrote.
public final class InboxCursorStore: InboxCursorStoring, @unchecked Sendable {
    public static let fileName = "inbox-cursor"

    private let folder: URL
    private let file: URL
    /// Serializes this store's writes; the file itself is replaced whole.
    private let lock = NSLock()

    /// `folder` is the support folder the file is kept in.
    public init(folder: URL) {
        self.folder = folder
        file = folder.appendingPathComponent(Self.fileName)
    }

    /// The stored number; 0 when the file is missing, cannot be read or
    /// does not hold a whole number of 0 or more.
    public func load() -> Int {
        lock.withLock {
            guard let data = FileManager.default.contents(atPath: file.path),
                let number = Int(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)),
                number >= 0
            else { return 0 }
            return number
        }
    }

    /// Writes the number. The file is mode 0600 from its first byte and is
    /// moved into place, so a failed write keeps the number that was there.
    public func save(_ seq: Int) throws {
        try lock.withLock {
            try FileManager.default.createDirectory(
                at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let temporary = file.path + ".new"
            unlink(temporary)
            let descriptor = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw InboxCursorStoreError.writeFailed(path: temporary, errno: errno) }
            let text = Array("\(seq)\n".utf8)
            var failure: Int32 = fchmod(descriptor, 0o600) == 0 ? 0 : errno
            var offset = 0
            while failure == 0, offset < text.count {
                let written = text.withUnsafeBytes { write(descriptor, $0.baseAddress! + offset, text.count - offset) }
                if written < 0 {
                    if errno != EINTR { failure = errno }
                } else {
                    offset += written
                }
            }
            close(descriptor)
            if failure == 0, rename(temporary, file.path) != 0 { failure = errno }
            guard failure == 0 else {
                unlink(temporary)
                throw InboxCursorStoreError.writeFailed(path: file.path, errno: failure)
            }
        }
    }
}
