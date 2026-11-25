import Foundation
import LeverageKit

/// The app's own log lines in `<support folder>/logs/app.log` (folder 0700,
/// file 0600), replaced once it passes its limit as the helper's log is, and
/// still written to standard error. When the file cannot be written the line
/// reaches standard error alone: a folder the app cannot write is one of the
/// reasons it logs.
public final class AppLogFile: @unchecked Sendable {
    public let url: URL
    private let limitBytes: Int
    private let alsoWrite: @Sendable (String) -> Void
    private let lock = NSLock()

    public init(
        supportFolder: URL, limitBytes: Int = 5_000_000,
        alsoWrite: @escaping @Sendable (String) -> Void = Log.standardError
    ) {
        url = supportFolder.appendingPathComponent("logs/app.log")
        self.limitBytes = limitBytes
        self.alsoWrite = alsoWrite
    }

    /// Takes one finished line, newline included, as `Log` hands it over.
    public func write(_ line: String) {
        alsoWrite(line)
        lock.withLock { append(Data(line.utf8)) }
    }

    private func append(_ data: Data) {
        let manager = FileManager.default
        let folder = url.deletingLastPathComponent()
        guard (try? manager.createDirectory(
            at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])) != nil
        else { return }
        let size = (try? manager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        if size > limitBytes {
            let older = folder.appendingPathComponent("app.log.1")
            try? manager.removeItem(at: older)
            try? manager.moveItem(at: url, to: older)
        }
        if !manager.fileExists(atPath: url.path) {
            guard manager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
            else { return }
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}
