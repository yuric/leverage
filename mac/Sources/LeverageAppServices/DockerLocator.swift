import Foundation
import LeverageKit

#if canImport(Darwin)
import Darwin
#endif

/// Finds the `docker` program in the folders it is given, and asks whether
/// the engine answers (plan PK-2, PK-3). It searches only what it is given:
/// the app passes `applicationFolders(home:)`, a test a temporary folder, so
/// a test can never reach the real Docker of the Mac it runs on.
public struct DockerLocator: Sendable {
    public let folders: [URL]
    private let isExecutable: @Sendable (String) -> Bool

    /// `isExecutable` answers whether a path is a program this user may
    /// run; the default asks the file system.
    public init(
        folders: [URL],
        isExecutable: @escaping @Sendable (String) -> Bool = DockerLocator.fileIsExecutable
    ) {
        self.folders = folders
        self.isExecutable = isExecutable
    }

    /// The folders the app searches, in order (PK-3).
    public static func applicationFolders(home: URL) -> [URL] {
        [
            URL(fileURLWithPath: "/usr/local/bin", isDirectory: true),
            URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true),
            URL(fileURLWithPath: dockerDesktopBin, isDirectory: true),
            home.appendingPathComponent(".docker/bin", isDirectory: true),
        ]
    }

    /// Where Docker Desktop keeps its programs, its credential helper among
    /// them.
    public static let dockerDesktopBin = "/Applications/Docker.app/Contents/Resources/bin"

    /// The first `docker` in the folders, or nil.
    public func locate() -> URL? {
        for folder in folders {
            let candidate = folder.appendingPathComponent("docker")
            if isExecutable(candidate.path) { return candidate }
        }
        return nil
    }

    /// The whole environment every `docker` command gets (PK-2): `HOME`,
    /// and a `PATH` of the folder `docker` was found in, Docker Desktop's
    /// own folder (its credential helper must be found there), `/usr/bin`
    /// and `/bin`. An app opened from Finder has no more on its `PATH`.
    public static func environment(docker: URL, home: URL) -> [String: String] {
        [
            EnvironmentKeys.home: home.path,
            EnvironmentKeys.path: [
                docker.deletingLastPathComponent().path, dockerDesktopBin, "/usr/bin", "/bin",
            ].joined(separator: ":"),
        ]
    }

    /// Whether the engine answers: `docker info` exits 0.
    public func engineIsAnswering(docker: URL, home: URL, runner: any ProcessRunning) async -> Bool {
        let request = SubprocessRequest(
            executable: docker.path,
            arguments: ["info", "--format", "{{.ServerVersion}}"],
            environment: Self.environment(docker: docker, home: home),
            timeLimit: .seconds(30))
        guard let result = try? await runner.run(request) else { return false }
        return result.succeeded
    }

    /// A regular file (after links) this user may execute.
    public static let fileIsExecutable: @Sendable (String) -> Bool = { path in
        var info = stat()
        return stat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG && access(path, X_OK) == 0
    }
}
