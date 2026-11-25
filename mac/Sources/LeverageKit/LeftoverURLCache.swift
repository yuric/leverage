import Foundation

/// What earlier versions left in the URL cache. They sent their API calls
/// through `URLSession.shared`, whose cache keeps each answer and its
/// request, bearer token included, in plain files under
/// `~/Library/Caches/<bundle id or program name>/`. `HTTPTransport` no
/// longer uses a cache, and each program removes its own leftover files
/// when it starts, before it makes a call.
///
/// Removing a file does not wipe the disk: an owner session that was in
/// one stays valid until the owner signs out.
public enum LeftoverURLCache {
    /// The URL cache's files in a program's cache folder. Anything else
    /// in the folder is left alone.
    static let files = ["Cache.db", "Cache.db-shm", "Cache.db-wal", "fsCachedData"]

    /// The folder names this program's URL cache has gone by: the bundle's
    /// id for a program in the app, the program's name for one run by
    /// itself.
    static var ownNames: [String] {
        var names: [String] = []
        for name in [Bundle.main.bundleIdentifier, ProcessInfo.processInfo.processName] {
            if let name, !name.isEmpty, !names.contains(name) { names.append(name) }
        }
        return names
    }

    /// Removes the URL cache files of `names` (this program's own when
    /// nil) under `cachesFolder` (the user's caches folder when nil), and
    /// says what it removed. A file that cannot be removed is left: the
    /// program starts all the same.
    @discardableResult
    public static func remove(cachesFolder: URL? = nil, names: [String]? = nil) -> [URL] {
        let manager = FileManager.default
        guard let caches = cachesFolder ?? manager.urls(for: .cachesDirectory, in: .userDomainMask).first
        else { return [] }
        var removed: [URL] = []
        // A name is one folder inside the caches folder, never a path.
        for name in names ?? ownNames where !name.isEmpty && name != "." && name != ".." && !name.contains("/") {
            let folder = caches.appendingPathComponent(name, isDirectory: true)
            for file in files {
                let url = folder.appendingPathComponent(file)
                guard manager.fileExists(atPath: url.path) else { continue }
                if (try? manager.removeItem(at: url)) != nil { removed.append(url) }
            }
        }
        return removed
    }
}
