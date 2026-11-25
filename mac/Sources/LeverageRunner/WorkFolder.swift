import Foundation
import LeverageKit
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Where the tool runs (CL-7). If the task's "Where the work is" names an
/// existing local folder, there. If it is empty, the builder makes
/// `<work root>/<task id>/` and submits that path as the work reference.
/// Anything else (an address, a relative path, a folder that does not
/// exist) cannot be worked on here: the builder releases with
/// `unable_to_continue`. The reviewer runs in the folder the reference
/// names and never makes one.
///
/// The reference is text a seat may write, and a build's tool may change
/// anything inside the folder it is run in, so some folders are never
/// used, whatever the reference says (`mayRunTool`): they are unusable
/// like a folder that does not exist.
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

    /// The folders that decide where a tool may be run.
    struct Places: Sendable {
        let home: String
        /// Leverage's support folder: the accounts, the tools, the server's
        /// settings and the backups.
        let supportFolder: String
        let workRoot: URL
    }

    static func builder(reference: String?, taskID: UUID, places: Places) -> Resolution {
        let given = reference?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if given.isEmpty {
            let made = places.workRoot.appendingPathComponent(taskID.contractString, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
            } catch {
                return .unusable
            }
            return .made(URL(fileURLWithPath: made.path, isDirectory: true))
        }
        guard let folder = existingFolder(given, places: places) else { return .unusable }
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

    static func reviewer(reference: String?, places: Places) -> URL? {
        let given = reference?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return given.isEmpty ? nil : existingFolder(given, places: places)
    }

    /// The folder an absolute path, a `~` path or a `file:` address names,
    /// when it exists.
    private static func existingFolder(_ reference: String, places: Places) -> URL? {
        let home = places.home
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
        guard mayRunTool(in: path, places: places) else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    // MARK: Where no tool is run

    /// Whether a tool may be run in the existing folder at `path`. Never in:
    ///
    /// - the Mac's root, the home folder, or a folder above it;
    /// - Leverage's support folder, a folder above it or a folder in it
    ///   (the accounts, the tools the helper runs next, the server's
    ///   settings, the backups), nor the work root itself or its `jobs`
    ///   folder; a task's own folder under the work root is used, since the
    ///   builder made it and submitted its path;
    /// - `~/Library`, which holds start-up items and other programs'
    ///   settings, except inside `CloudStorage` and `Mobile Documents`,
    ///   where cloud drives keep the owner's documents.
    ///
    /// Folders are compared by what they are on disk, not by how the path
    /// is spelled, so a link to a refused folder, or its name in another
    /// case on a disk that ignores case, is refused too.
    static func mayRunTool(in path: String, places: Places) -> Bool {
        let folder = Lineage(of: path)
        guard folder.exists, let itself = folder.identities.first else { return false }
        let above = folder.identities.dropFirst()
        if above.isEmpty { return false }

        /// Whether the folder is `other`, when `other` exists.
        func equals(_ other: Lineage) -> Bool { other.exists && other.identities.first == itself }
        /// Whether the folder lies inside `other`, at any depth.
        func isInside(_ other: Lineage) -> Bool {
            guard other.exists, let identity = other.identities.first else { return false }
            return above.contains(identity)
        }
        /// Whether the folder is `other` or a folder above it, also when
        /// `other` does not exist yet.
        func isOrHolds(_ other: Lineage) -> Bool { other.identities.contains(itself) }

        if isOrHolds(Lineage(of: places.home)) { return false }

        let workRoot = Lineage(of: places.workRoot.path)
        let jobs = Lineage(of: places.workRoot.appendingPathComponent("jobs").path)
        if equals(workRoot) || equals(jobs) || isInside(jobs) { return false }
        if isInside(workRoot) { return true }

        let support = Lineage(of: places.supportFolder)
        if isOrHolds(support) || isInside(support) { return false }

        let libraryPath = places.home + "/Library"
        let library = Lineage(of: libraryPath)
        if equals(library) { return false }
        if isInside(library) {
            return isInside(Lineage(of: libraryPath + "/CloudStorage"))
                || isInside(Lineage(of: libraryPath + "/Mobile Documents"))
        }
        return true
    }

    /// What a folder is on disk: its volume and its number there.
    private struct Identity: Equatable {
        let volume: UInt64
        let file: UInt64

        /// Of what the path names once every link is followed, or nil when
        /// it names nothing. One `stat` call: this is asked for every
        /// folder above a work folder, before every tool run.
        init?(path: String) {
            var information = stat()
            guard stat(path, &information) == 0 else { return nil }
            volume = UInt64(truncatingIfNeeded: information.st_dev)
            file = UInt64(truncatingIfNeeded: information.st_ino)
        }
    }

    /// The folder a path names and every folder above it, the folder first,
    /// each as what it is on disk once every link is followed. For a path
    /// that names nothing, `exists` is false and the list starts at the
    /// nearest folder above it that exists.
    private struct Lineage {
        let exists: Bool
        let identities: [Identity]

        init(of path: String) {
            var named = URL(fileURLWithPath: path).standardized.path
            var exists = true
            while named != "/", Identity(path: named) == nil {
                named = Self.parent(of: named)
                exists = false
            }
            // With its links followed, the path's parents are the folders
            // above it.
            var real = URL(fileURLWithPath: named).resolvingSymlinksInPath().path
            var identities: [Identity] = []
            while true {
                if let identity = Identity(path: real) { identities.append(identity) }
                if real == "/" { break }
                real = Self.parent(of: real)
            }
            self.exists = exists
            self.identities = identities
        }

        /// The folder above an absolute path with no `.`, `..` or doubled
        /// slash in it; the root's is the root.
        private static func parent(of path: String) -> String {
            guard let slash = path.lastIndex(of: "/"), slash != path.startIndex else { return "/" }
            return String(path[..<slash])
        }
    }
}
