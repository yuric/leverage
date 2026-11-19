import Foundation
import LeverageKit

/// A provider's tool that was found and answered its version.
struct LocatedTool: Equatable, Sendable {
    let path: String
    let version: String
}

/// Finds a provider's tool and its version (PV-3): only in `LEVERAGE_TOOL_DIR`
/// when that is set; otherwise where leverage installs an archive, the
/// vendors' folders, then the helper's `PATH`.
struct ToolLocator: Sendable {
    let settings: HelperSettings
    let timings: HelperTimings

    /// The folders looked in, in order.
    func searchFolders(for entry: ProviderEntry) -> [String] {
        var folders = ProviderCatalog.searchFolders(
            for: entry.id, home: settings.home, supportFolder: settings.supportFolder.path,
            toolDir: settings.toolDir)
        if settings.toolDir == nil {
            let path = settings.environment[EnvironmentKeys.path] ?? ""
            for folder in path.split(separator: ":").map(String.init)
            where folder.hasPrefix("/") && !folders.contains(folder) {
                folders.append(folder)
            }
        }
        return folders
    }

    /// The first program of the tool's name in the search folders; nothing
    /// is run.
    func find(_ entry: ProviderEntry) -> String? {
        for folder in searchFolders(for: entry) {
            let candidate = URL(fileURLWithPath: folder).appendingPathComponent(entry.toolName).path
            var isFolder: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate, isDirectory: &isFolder), !isFolder.boolValue,
               FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    /// The tool, when it is found and its version command exits 0 within
    /// the command limit.
    func locate(_ entry: ProviderEntry) async -> LocatedTool? {
        guard let path = find(entry) else { return nil }
        guard let result = try? await Subprocess.run(SubprocessRequest(
            executable: path, arguments: entry.version.value,
            environment: toolEnvironment(entry, toolPath: path, accountFolder: nil),
            timeLimit: timings.commandLimit, gracePeriod: .seconds(2))),
            result.succeeded
        else { return nil }
        return LocatedTool(path: path, version: Self.version(from: result))
    }

    /// The tool's whole environment (CL-10), from the catalog's allow-list.
    func toolEnvironment(_ entry: ProviderEntry, toolPath: String, accountFolder: URL?) -> [String: String] {
        ProviderCatalog.toolEnvironment(
            for: entry, from: settings.environment,
            toolFolder: URL(fileURLWithPath: toolPath).deletingLastPathComponent().path,
            accountFolder: accountFolder?.path, supportFolder: settings.supportFolder.path,
            toolDir: settings.toolDir)
    }

    /// The first line the version command printed, on standard output or
    /// else standard error; "unknown" when it printed none.
    static func version(from result: SubprocessResult) -> String {
        for output in [result.standardOutput, result.standardError] {
            let text = String(decoding: output, as: UTF8.self)
            if let line = text.split(whereSeparator: \.isNewline).first?
                .trimmingCharacters(in: .whitespaces), !line.isEmpty {
                return String(line.prefix(200))
            }
        }
        return "unknown"
    }
}
