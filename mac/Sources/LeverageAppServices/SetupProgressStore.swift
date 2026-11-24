import Foundation
import LeverageKit

public enum SetupProgressStoreError: Error, Equatable, Sendable {
    /// The file could not be written; its path.
    case writeFailed(path: String)
}

/// `SetupProgressStoring` on one small file in the support folder, mode
/// 0600: the owner's setup choice as one word (docs/onboarding/PRD.md). No
/// secret. A new store on the same folder reads what the last one wrote, so
/// the choice outlives the app.
public final class SetupProgressStore: SetupProgressStoring, @unchecked Sendable {
    public static let fileName = "setup-progress"

    private let folder: URL
    private let file: URL
    /// Serializes this store's writes; the file itself is replaced whole.
    private let lock = NSLock()

    /// `folder` is the support folder the file is kept in.
    public init(folder: URL) {
        self.folder = folder
        file = folder.appendingPathComponent(Self.fileName)
    }

    /// The stored choice; `.notChosen` when the file is missing, cannot be
    /// read or holds anything but one of the choices.
    public func load() -> SetupChoice {
        lock.withLock {
            guard let data = FileManager.default.contents(atPath: file.path) else { return .notChosen }
            let word = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return SetupChoice(rawValue: word) ?? .notChosen
        }
    }

    /// Writes the choice. The file is written beside its place and moved in,
    /// so a failed write keeps the choice that was there.
    public func save(_ choice: SetupChoice) throws {
        try lock.withLock {
            do {
                try FileManager.default.createDirectory(
                    at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try Data("\(choice.rawValue)\n".utf8).write(to: file, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            } catch {
                throw SetupProgressStoreError.writeFailed(path: file.path)
            }
        }
    }
}
