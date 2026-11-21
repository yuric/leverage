import Foundation
import LeverageKit

/// Where the tool runs (CL-7). If the task's "Where the work is" names an
/// existing local folder, there. If it is empty, the builder makes
/// `<work root>/<task id>/` and submits that path as the work reference.
/// Anything else (an address, a relative path, a folder that does not
/// exist) cannot be worked on here: the builder releases with
/// `unable_to_continue`. The reviewer runs in the folder the reference
/// names and never makes one.
enum WorkFolder {
    enum Resolution: Equatable, Sendable {
        /// An existing folder; the reference is submitted as it was given.
        case existing(URL, reference: String)
        /// The folder made for a task with no reference; its path is the
        /// reference submitted.
        case made(URL)
        case unusable

        var folder: URL? {
            switch self {
            case .existing(let url, _), .made(let url): url
            case .unusable: nil
            }
        }

        /// The work reference the builder submits.
        var reference: String? {
            switch self {
            case .existing(_, let reference): reference
            case .made(let url): url.path
            case .unusable: nil
            }
        }
    }

    static func builder(reference: String?, taskID: UUID, workRoot: URL, home: String) -> Resolution {
        let given = reference?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if given.isEmpty {
            let made = workRoot.appendingPathComponent(taskID.contractString, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
            } catch {
                return .unusable
            }
            return .made(URL(fileURLWithPath: made.path, isDirectory: true))
        }
        guard let folder = existingFolder(given, home: home) else { return .unusable }
        return .existing(folder, reference: reference ?? given)
    }

    /// A new empty folder for one tool run of a job, under `<work root>/jobs/`,
    /// which the caller removes with `removeJobFolder` after the run (RD-33).
    /// Nil when it cannot be made.
    static func makeJobFolder(workRoot: URL) -> URL? {
        let folder = workRoot.appendingPathComponent("jobs", isDirectory: true)
            .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            return nil
        }
        return URL(fileURLWithPath: folder.path, isDirectory: true)
    }

    /// Removes a job's folder and whatever a tool left in it.
    static func removeJobFolder(_ folder: URL) {
        try? FileManager.default.removeItem(at: folder)
    }

    static func reviewer(reference: String?, home: String) -> URL? {
        let given = reference?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return given.isEmpty ? nil : existingFolder(given, home: home)
    }

    /// The folder an absolute path, a `~` path or a `file:` address names,
    /// when it exists.
    private static func existingFolder(_ reference: String, home: String) -> URL? {
        var path: String
        if reference == "~" {
            path = home
        } else if reference.hasPrefix("~/") {
            path = home + reference.dropFirst()
        } else if reference.lowercased().hasPrefix("file:"), let url = URL(string: reference), url.isFileURL {
            path = url.path
        } else {
            path = reference
        }
        guard path.hasPrefix("/") else { return nil }
        path = URL(fileURLWithPath: path).standardized.path
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isFolder), isFolder.boolValue else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}
