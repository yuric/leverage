import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Notices that the process which started this one is gone (PK-8): a
/// crashed or force-quit app tells no child, so the helper watches the app
/// and then stops its runs and exits, and a runner watches the helper and
/// then stops as on SIGTERM. On macOS a process source reports the exit; on
/// Linux (the end-to-end job) the process is looked at every `interval`.
/// Either way a process already gone when the watch starts is noticed at
/// once, and `onGone` is called once.
public final class ParentWatch: @unchecked Sendable {
    public let pid: pid_t
    public let interval: Duration
    /// When the process watched is this process's parent, being given
    /// another parent also means it is gone.
    private let isParent: Bool
    private let onGone: @Sendable () -> Void

    private let lock = NSLock()
    // Guarded by `lock`.
    private var fired = false
    private var cancelled = false
    #if canImport(Darwin)
    private var source: (any DispatchSourceProcess)?
    #endif
    private var poller: Task<Void, Never>?

    public init(watching pid: pid_t, interval: Duration = .seconds(2), onGone: @escaping @Sendable () -> Void) {
        self.pid = pid
        self.interval = interval
        self.isParent = pid == getppid()
        self.onGone = onGone
    }

    public func start() {
        #if canImport(Darwin)
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global())
        source.setEventHandler { [weak self] in self?.fire() }
        lock.withLock { self.source = source }
        source.resume()
        #endif
        // The look also covers a process gone before the source existed,
        // and is the whole watch where there is no process source.
        let poller = Task { [weak self, pid, interval, isParent] in
            while !Task.isCancelled {
                if !Self.exists(pid) || (isParent && getppid() != pid) {
                    self?.fire()
                    return
                }
                try? await Task.sleep(for: interval)
            }
        }
        lock.withLock { self.poller = poller }
    }

    public func cancel() {
        lock.withLock {
            cancelled = true
            #if canImport(Darwin)
            source?.cancel()
            source = nil
            #endif
            poller?.cancel()
            poller = nil
        }
    }

    private func fire() {
        let first = lock.withLock {
            guard !fired, !cancelled else { return false }
            fired = true
            return true
        }
        if first { onGone() }
    }

    /// False once the process is gone or is a zombie waiting for its
    /// parent; true while it runs or while it is not ours to signal.
    public static func exists(_ pid: pid_t) -> Bool {
        if kill(pid, 0) != 0 { return errno == EPERM }
        #if canImport(Darwin)
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&name, 4, &info, &size, nil, 0) == 0, size > 0 else { return true }
        return info.kp_proc.p_stat != SZOMB
        #else
        guard let stat = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8),
              let close = stat.lastIndex(of: ")")
        else { return true }
        return !stat[close...].hasPrefix(") Z")
        #endif
    }
}
