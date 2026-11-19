import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A new, empty folder of a test's own under the system's temporary folder,
/// removed when the value is released (or by `remove()`).
///
/// The path has its symbolic links resolved (on macOS `/var` is a link to
/// `/private/var`), so a path a child process reports back compares equal.
public final class TemporaryFolder: @unchecked Sendable {
    public let url: URL

    public init(prefix: String = "leverage-test") throws {
        let template = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-XXXXXX").path
        var bytes = Array(template.utf8CString)
        guard let made = mkdtemp(&bytes) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let path = String(cString: made)
        url = URL(fileURLWithPath: resolvedPath(path) ?? path, isDirectory: true)
    }

    deinit { remove() }

    /// A path inside the folder; nothing is created.
    public func path(_ components: String...) -> URL {
        components.reduce(url) { $0.appendingPathComponent($1) }
    }

    /// Creates a folder inside this one and returns it.
    @discardableResult
    public func folder(_ name: String) throws -> URL {
        let made = url.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
        return made
    }

    public func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

private func resolvedPath(_ path: String) -> String? {
    guard let resolved = realpath(path, nil) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
}
