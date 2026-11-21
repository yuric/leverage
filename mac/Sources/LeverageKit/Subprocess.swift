import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// The one way the Mac side runs a child process (plan CL-10, CL-23): the
// environment is exactly the one given, built from an allow-list and never
// the parent's; standard input is /dev/null; the child leads a process group
// of its own; both outputs are read while it runs, so output larger than a
// pipe's buffer cannot stall it; and a time limit or a stop ends the whole
// group, first asking (SIGTERM) and then forcing (SIGKILL). When the child
// exits, whatever it left running in its group is ended the same way.
//
// Built on posix_spawn, which exists on macOS and Linux, so the helper and
// the runner build for the Linux end-to-end job too. A process that leaves
// the group (setsid) is out of reach; no tool the runner drives is known to.

/// What to run.
public struct SubprocessRequest: Sendable {
    /// An absolute path: nothing is looked up in a `PATH`.
    public var executable: String
    public var arguments: [String]
    /// The child's whole environment. Build it with
    /// `Subprocess.environment(allowing:from:setting:)`.
    public var environment: [String: String]
    public var workingDirectory: String?
    /// When it passes, the child's group is ended and the result says
    /// `endedBy: .timeLimit`.
    public var timeLimit: Duration?
    /// How long a request to end (SIGTERM) is given before it is forced.
    public var gracePeriod: Duration
    /// Output past this many bytes, on each of the two outputs, is read
    /// and dropped.
    public var maximumOutputBytes: Int

    public init(
        executable: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: String? = nil,
        timeLimit: Duration? = nil,
        gracePeriod: Duration = .seconds(5),
        maximumOutputBytes: Int = 64 << 20
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.timeLimit = timeLimit
        self.gracePeriod = gracePeriod
        self.maximumOutputBytes = maximumOutputBytes
    }
}

/// How the child ended.
public enum SubprocessTermination: Equatable, Sendable {
    case exited(Int32)
    case signaled(Int32)
}

/// Why leverage ended the child, when it did.
public enum SubprocessEnd: Equatable, Sendable {
    case timeLimit
    case stop
}

public struct SubprocessResult: Equatable, Sendable {
    public let termination: SubprocessTermination
    public let standardOutput: Data
    public let standardError: Data
    /// Nil when the child ended by itself.
    public let endedBy: SubprocessEnd?
    /// True when either output passed `maximumOutputBytes`.
    public let outputTruncated: Bool

    /// Exited 0 by itself.
    public var succeeded: Bool { termination == .exited(0) && endedBy == nil }
}

public enum SubprocessError: Error, Equatable, Sendable {
    case notAbsolute(String)
    case notExecutable(String)
    /// A system call failed before the child started, with its errno.
    case startFailed(call: String, errno: Int32)
}

public enum SubprocessInputError: Error, Equatable, Sendable {
    case closed
    case invalidLine
    case writeFailed(errno: Int32)
}

public enum Subprocess {
    /// An environment of exactly the `allowing` names that `source` has, and
    /// then the `setting` values, which win.
    public static func environment(
        allowing names: [String],
        from source: [String: String],
        setting values: [String: String] = [:]
    ) -> [String: String] {
        var built: [String: String] = [:]
        for name in names {
            if let value = source[name] { built[name] = value }
        }
        built.merge(values) { _, set in set }
        return built
    }

    /// Starts the child. Its result comes from `wait()`.
    public static func start(_ request: SubprocessRequest) throws -> RunningSubprocess {
        try RunningSubprocess(request)
    }

    public static func startSession(_ request: SubprocessRequest) throws -> RunningSubprocess {
        try start(request)
    }

    /// Runs the child to its end. Cancelling the calling task stops it.
    public static func run(_ request: SubprocessRequest) async throws -> SubprocessResult {
        let child = try start(request)
        return await withTaskCancellationHandler {
            await child.wait()
        } onCancel: {
            child.stop()
        }
    }
}

/// A started child process.
public final class RunningSubprocess: @unchecked Sendable {
    public let processID: pid_t

    private let request: SubprocessRequest
    private let lock = NSLock()
    // Guarded by `lock`.
    private var reaped = false
    private var endedBy: SubprocessEnd?
    private var result: SubprocessResult?
    private var waiters: [CheckedContinuation<SubprocessResult, Never>] = []

    private let output: PipeReader
    private let error: PipeReader

    fileprivate init(_ request: SubprocessRequest) throws {
        guard request.executable.hasPrefix("/") else {
            throw SubprocessError.notAbsolute(request.executable)
        }
        var info = stat()
        guard stat(request.executable, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              access(request.executable, X_OK) == 0 else {
            throw SubprocessError.notExecutable(request.executable)
        }
        self.request = request

        let outPipe = try makePipe()
        let errPipe: (read: Int32, write: Int32)
        do {
            errPipe = try makePipe()
        } catch {
            close(outPipe.read); close(outPipe.write)
            throw error
        }
        let spawned: pid_t
        do {
            spawned = try spawn(request, stdout: outPipe.write, stderr: errPipe.write)
        } catch {
            for fd in [outPipe.read, outPipe.write, errPipe.read, errPipe.write] { close(fd) }
            throw error
        }
        close(outPipe.write)
        close(errPipe.write)
        processID = spawned
        output = PipeReader(fd: outPipe.read, limit: request.maximumOutputBytes)
        error = PipeReader(fd: errPipe.read, limit: request.maximumOutputBytes)

        if let limit = request.timeLimit {
            DispatchQueue.global().asyncAfter(deadline: .now() + limit.dispatchInterval) { [weak self] in
                self?.end(because: .timeLimit)
            }
        }
        let monitor = Thread { [self] in monitorUntilReaped() }
        monitor.name = "Subprocess \(spawned)"
        monitor.start()
    }

    /// Ends the child and everything in its group: asks, then forces after
    /// the grace period. The result says `endedBy: .stop`.
    public func stop() {
        end(because: .stop)
    }

    public func writeLine(_ line: Data) async throws {
        throw SubprocessInputError.closed
    }

    public func readLine() async -> Data? { nil }

    public func closeInput() {}

    /// The result, once the child has ended and its outputs are read.
    public func wait() async -> SubprocessResult {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(returning: result)
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    // MARK: - Ending the group

    private func end(because reason: SubprocessEnd) {
        lock.lock()
        guard endedBy == nil, result == nil, !reaped else {
            lock.unlock()
            return
        }
        endedBy = reason
        lock.unlock()
        signalGroup(SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + request.gracePeriod.dispatchInterval) {
            [weak self] in self?.signalGroup(SIGKILL)
        }
    }

    /// Signals the child's group, but never after the child is reaped: until
    /// then its process id, which is the group's id, cannot be reused.
    private func signalGroup(_ signal: Int32) {
        lock.lock()
        defer { lock.unlock() }
        if !reaped { _ = killpg(processID, signal) }
    }

    private func monitorUntilReaped() {
        // Wait for the child to exit without reaping it.
        var info = siginfo_t()
        while waitid(P_PID, id_t(processID), &info, WEXITED | WNOWAIT) != 0 && errno == EINTR {}

        // End what it left running in its group: let the outputs drain a
        // moment, ask, give the grace period, then force.
        _ = PipeReader.waitForBoth(output, error, seconds: 0.25)
        signalGroup(SIGTERM)
        if !PipeReader.waitForBoth(output, error, seconds: request.gracePeriod.seconds) {
            signalGroup(SIGKILL)
            _ = PipeReader.waitForBoth(output, error, seconds: 2)
        } else {
            signalGroup(SIGKILL)
        }
        output.finish()
        error.finish()

        lock.lock()
        reaped = true
        lock.unlock()
        var status: Int32 = 0
        while waitpid(processID, &status, 0) < 0 && errno == EINTR {}

        let termination: SubprocessTermination = (status & 0x7f) == 0
            ? .exited((status >> 8) & 0xff)
            : .signaled(status & 0x7f)
        lock.lock()
        let finished = SubprocessResult(
            termination: termination,
            standardOutput: output.data,
            standardError: error.data,
            endedBy: endedBy,
            outputTruncated: output.truncated || error.truncated)
        result = finished
        let ready = waiters
        waiters = []
        lock.unlock()
        for waiter in ready { waiter.resume(returning: finished) }
    }
}

// MARK: - Reading an output

/// Reads one pipe on a thread of its own until end of file.
private final class PipeReader: @unchecked Sendable {
    private let fd: Int32
    private let limit: Int
    private let done = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var buffer = Data()
    private var dropped = false
    private var closed = false
    // Set once the reading thread has signalled end of file.
    private var finished = false
    // Set when `finish()` gave up waiting: the reading thread then drops
    // what it reads and closes the descriptor itself.
    private var abandoned = false

    init(fd: Int32, limit: Int) {
        self.fd = fd
        self.limit = limit
        let thread = Thread { [self] in readToEnd() }
        thread.name = "Subprocess output \(fd)"
        thread.start()
    }

    var data: Data { lock.withLock { buffer } }
    var truncated: Bool { lock.withLock { dropped } }

    /// True when both readers reached end of file within `seconds`.
    static func waitForBoth(_ one: PipeReader, _ two: PipeReader, seconds: Double) -> Bool {
        let deadline = DispatchTime.now() + seconds
        return one.waitUntil(deadline) && two.waitUntil(deadline)
    }

    private func waitUntil(_ deadline: DispatchTime) -> Bool {
        if lock.withLock({ finished }) { return true }
        guard done.wait(timeout: deadline) == .success else { return false }
        lock.withLock { finished = true }
        return true
    }

    /// Stops reading: closes the read end once the reader is done, or
    /// leaves it to the reader, which then stops at its next read.
    func finish() {
        _ = waitUntil(.now() + 0.5)
        lock.withLock {
            if finished, !closed {
                closed = true
                close(fd)
            } else if !finished {
                // A writer still holds the pipe after SIGKILL (it left the
                // group). Closing the descriptor here would race the reading
                // thread, so the thread keeps it and closes it at end of file.
                abandoned = true
            }
        }
    }

    private func readToEnd() {
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                lock.withLock {
                    if abandoned { return }
                    let room = max(0, limit - buffer.count)
                    if count > room { dropped = true }
                    buffer.append(contentsOf: chunk[0..<min(count, room)])
                }
            } else if count < 0 && errno == EINTR {
                continue
            } else {
                break
            }
        }
        let closeHere = lock.withLock { () -> Bool in
            if abandoned, !closed {
                closed = true
                return true
            }
            return false
        }
        if closeHere { close(fd) }
        done.signal()
    }
}

// MARK: - Spawning

private func makePipe() throws -> (read: Int32, write: Int32) {
    var fds: [Int32] = [-1, -1]
    guard pipe(&fds) == 0 else { throw SubprocessError.startFailed(call: "pipe", errno: errno) }
    for fd in fds { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
    return (fds[0], fds[1])
}

private func spawn(_ request: SubprocessRequest, stdout: Int32, stderr: Int32) throws -> pid_t {
    #if canImport(Darwin)
    let executable = request.executable
    let argv = [request.executable] + request.arguments
    var actions: posix_spawn_file_actions_t?
    var attributes: posix_spawnattr_t?
    #else
    var actions = posix_spawn_file_actions_t()
    var attributes = posix_spawnattr_t()
    var executable = request.executable
    var argv = [request.executable] + request.arguments
    // Glibc's posix_spawn_file_actions_addchdir_np is not reliably visible
    // to Swift, so on Linux a POSIX shell changes folder and then becomes
    // the program (exec), keeping its process id and group.
    if let folder = request.workingDirectory {
        executable = "/bin/sh"
        argv = ["/bin/sh", "-c", "cd -- \"$0\" && exec \"$@\"", folder] + argv
    }
    #endif
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }

    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_adddup2(&actions, stdout, 1)
    posix_spawn_file_actions_adddup2(&actions, stderr, 2)
    #if canImport(Darwin)
    if let folder = request.workingDirectory {
        posix_spawn_file_actions_addchdir_np(&actions, folder)
    }
    #endif

    var flags = Int32(POSIX_SPAWN_SETPGROUP) | Int32(POSIX_SPAWN_SETSIGMASK) | Int32(POSIX_SPAWN_SETSIGDEF)
    #if canImport(Darwin)
    // Every descriptor the file actions do not name is closed in the child.
    flags |= Int32(POSIX_SPAWN_CLOEXEC_DEFAULT)
    #endif
    posix_spawnattr_setflags(&attributes, Int16(flags))
    posix_spawnattr_setpgroup(&attributes, 0)
    var noSignals = sigset_t()
    sigemptyset(&noSignals)
    posix_spawnattr_setsigmask(&attributes, &noSignals)
    var defaults = sigset_t()
    sigemptyset(&defaults)
    for signal in [SIGPIPE, SIGTERM, SIGINT, SIGHUP, SIGQUIT, SIGCHLD, SIGALRM, SIGUSR1, SIGUSR2] {
        sigaddset(&defaults, signal)
    }
    posix_spawnattr_setsigdefault(&attributes, &defaults)

    let environment = request.environment.map { "\($0.key)=\($0.value)" }.sorted()
    var pid: pid_t = 0
    let status = withCStrings(argv) { argvPointer in
        withCStrings(environment) { envPointer in
            posix_spawn(&pid, executable, &actions, &attributes, argvPointer, envPointer)
        }
    }
    guard status == 0 else { throw SubprocessError.startFailed(call: "posix_spawn", errno: status) }
    return pid
}

private func withCStrings<Result>(
    _ strings: [String], _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> Result
) -> Result {
    var pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
    pointers.append(nil)
    defer { for pointer in pointers { free(pointer) } }
    return pointers.withUnsafeBufferPointer { body($0.baseAddress!) }
}

extension Duration {
    fileprivate var seconds: Double {
        let (whole, fraction) = components
        return Double(whole) + Double(fraction) / 1e18
    }

    fileprivate var dispatchInterval: DispatchTimeInterval {
        .nanoseconds(Int(min(seconds * 1e9, Double(Int.max / 2))))
    }
}
