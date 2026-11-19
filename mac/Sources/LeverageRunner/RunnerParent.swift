import Foundation
import LeverageKit

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The runner's watch on the helper that started it (PK-8, CL-23). A helper
/// that crashes or is killed tells no child, and the runner's process group
/// is its own, so without this the runner would keep working with a live
/// seat token until the next helper token ended it. When the helper is
/// gone, `onGone` is called once: main.swift passes the same stop SIGTERM
/// starts.
enum RunnerParent {
    /// Watches `parent`, nil when there is no parent to watch (it is
    /// already launchd, pid 1: the helper was gone before the runner
    /// looked).
    static func watch(
        parent: pid_t = getppid(), interval: Duration = .seconds(2), onGone: @escaping @Sendable () -> Void
    ) -> ParentWatch? {
        guard parent > 1 else { return nil }
        let watch = ParentWatch(watching: parent, interval: interval, onGone: onGone)
        watch.start()
        return watch
    }
}
