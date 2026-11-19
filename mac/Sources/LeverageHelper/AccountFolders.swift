import Foundation
import LeverageKit

/// The settings folder of each login of a provider that keeps its accounts
/// in folders (L584, CL-9, CL-18): `<support folder>/accounts/<credential id>`.
/// The helper creates it and never adopts one: whatever is already at that
/// place (an earlier try's folder, or a link to another program's) is
/// removed first, never used, and a link's target is never touched.
struct AccountFolders: Sendable {
    let root: URL

    init(supportFolder: URL) {
        root = supportFolder.appendingPathComponent("accounts", isDirectory: true)
    }

    func folder(for credential: UUID) -> URL {
        root.appendingPathComponent(credential.contractString, isDirectory: true)
    }

    /// A new, empty folder, readable by this user only.
    func createFresh(for credential: UUID) throws -> URL {
        let files = FileManager.default
        try files.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let place = folder(for: credential)
        if (try? files.attributesOfItem(atPath: place.path)) != nil {
            // removeItem removes a link itself, never what it points to.
            try files.removeItem(at: place)
        }
        try files.createDirectory(at: place, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: place.path)
        return place
    }

    /// The folder an add made, when it is there and is a real folder.
    func existing(for credential: UUID) -> URL? {
        let place = folder(for: credential)
        guard let kind = try? FileManager.default.attributesOfItem(atPath: place.path)[.type] as? FileAttributeType,
              kind == .typeDirectory
        else { return nil }
        return place
    }

    /// Deletes the folder and everything the sign-in wrote into it.
    func remove(for credential: UUID) {
        try? FileManager.default.removeItem(at: folder(for: credential))
    }
}
