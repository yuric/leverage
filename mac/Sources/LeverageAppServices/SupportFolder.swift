import Foundation
import LeverageKit

/// The app's support folder: `~/Library/Application Support/leverage`, or
/// the absolute path in `LEVERAGE_SUPPORT_DIR` (tests and the smoke run).
public struct SupportFolder: Equatable, Sendable {
    public let url: URL

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        if let override = environment[EnvironmentKeys.supportDir], override.hasPrefix("/") {
            url = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            url = home.appendingPathComponent("Library/Application Support/leverage", isDirectory: true)
        }
    }
}
