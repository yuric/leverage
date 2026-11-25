import Foundation
import LeverageKit

/// The app's support folder: `~/Library/Application Support/leverage`, or
/// the absolute path in `LEVERAGE_SUPPORT_DIR` (tests and the smoke run).
public struct SupportFolder: Equatable, Sendable {
    public let url: URL
    /// Nil for the standard folder. For any other folder, eight hex digits
    /// drawn from its path, which name its own compose project and Keychain
    /// account, so that a second folder never takes over the owner's server
    /// or signs the owner out.
    public let isolationSuffix: String?

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        let standard = home.appendingPathComponent("Library/Application Support/leverage", isDirectory: true)
        if let override = environment[EnvironmentKeys.supportDir], override.hasPrefix("/") {
            url = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            url = standard
        }
        let path = url.standardizedFileURL.path
        isolationSuffix = path == standard.standardizedFileURL.path ? nil : Self.suffix(of: path)
    }

    /// FNV-1a over the path's bytes, folded to 32 bits: stable across
    /// launches and builds, unlike `hashValue`.
    private static func suffix(of path: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in path.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        let folded = UInt32(truncatingIfNeeded: hash ^ (hash >> 32))
        let hex = String(folded, radix: 16)
        return String(repeating: "0", count: 8 - hex.count) + hex
    }
}
