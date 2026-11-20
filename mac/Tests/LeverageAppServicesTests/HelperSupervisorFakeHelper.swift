import Foundation
import LeverageTestSupport
import Testing

#if canImport(Darwin)
import Darwin
#endif

/// A fake helper program in a temporary folder. Run n records its process
/// id in `state/pid-<n>`, its environment in `state/env-<n>` and its
/// arguments in `state/args-<n>`, writes one line to standard error, and
/// then exits with line n of `state/codes`, or, past the end of that file,
/// runs until it is asked to stop.
///
/// Asked to stop (SIGTERM), run n ends at once, unless the test holds it
/// (`holdOnStop(run:)`): it then ends only once the test lets it go
/// (`letGo(run:)`), as a helper that waits for its runners does.
///
/// A test ends with `expectNothingLeft()`: every run has ended, and the
/// folder is removed.
final class FakeHelperProgram: @unchecked Sendable {
    let folder: TemporaryFolder
    var program: URL { folder.url.appendingPathComponent("bin/LeverageHelper") }
    var state: URL { folder.url.appendingPathComponent("state") }
    var support: URL { folder.url.appendingPathComponent("support") }

    init(exitCodes: [Int32]) throws {
        folder = try TemporaryFolder(prefix: "leverage-helper-supervisor")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        try Data(exitCodes.map { "\($0)\n" }.joined().utf8).write(to: state.appendingPathComponent("codes"))
        let dir = state.path
        try writeScript(program, """
            #!/bin/sh
            dir='\(dir)'
            n=$(( $(cat "$dir/count" 2>/dev/null || echo 0) + 1 ))
            # The trap is set before the run is counted: a test that stops the
            # helper as soon as it sees the count still finds the run's line.
            trap 'echo "fake helper run $n asked to stop" >&2
                while [ -e "$dir/hold-$n" ]; do sleep 0.05; done
                exit 0' TERM
            echo $$ > "$dir/pid-$n"
            echo "$n" > "$dir/count"
            env | grep -v -E '^(PWD|OLDPWD|SHLVL|_)=' | sort > "$dir/env-$n"
            printf '%s\\n' "$0" "$@" > "$dir/args-$n"
            echo "fake helper run $n" >&2
            code=$(sed -n "${n}p" "$dir/codes")
            if [ -n "$code" ]; then exit "$code"; fi
            while :; do sleep 0.05; done
            """)
    }

    /// The last resort when a test ended before `expectNothingLeft()`:
    /// nothing of the fake outlives the value.
    deinit {
        endWhatStillRuns()
        folder.remove()
    }

    var runs: Int {
        Int((try? String(contentsOf: state.appendingPathComponent("count"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
    }

    func environment(ofRun n: Int) -> [String: String] {
        let text = (try? String(contentsOf: state.appendingPathComponent("env-\(n)"), encoding: .utf8)) ?? ""
        var found: [String: String] = [:]
        for line in text.split(separator: "\n") {
            if let equals = line.firstIndex(of: "=") {
                found[String(line[..<equals])] = String(line[line.index(after: equals)...])
            }
        }
        return found
    }

    func arguments(ofRun n: Int) -> String {
        (try? String(contentsOf: state.appendingPathComponent("args-\(n)"), encoding: .utf8)) ?? ""
    }

    /// What every run wrote to the helper's log.
    var log: String {
        (try? String(contentsOf: support.appendingPathComponent("logs/helper.log"), encoding: .utf8)) ?? ""
    }

    // MARK: Holding a run that was asked to stop

    func holdOnStop(run n: Int) throws {
        try Data().write(to: state.appendingPathComponent("hold-\(n)"))
    }

    func letGo(run n: Int) {
        try? FileManager.default.removeItem(at: state.appendingPathComponent("hold-\(n)"))
    }

    // MARK: The runs' processes

    /// The process id run n recorded, nil before it started.
    func processID(ofRun n: Int) -> pid_t? {
        (try? String(contentsOf: state.appendingPathComponent("pid-\(n)"), encoding: .utf8))
            .flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    /// True while run n's process is alive and is still this fake: a
    /// process id the system gave to another program since does not count.
    func isRunning(run n: Int) -> Bool {
        guard let pid = processID(ofRun: n) else { return false }
        return isThisFake(pid)
    }

    /// The runs whose process is still alive.
    var runsStillRunning: [Int] {
        guard runs > 0 else { return [] }
        return (1...runs).filter(isRunning(run:))
    }

    /// Every run has ended (waiting as patiently as the run asks), and the
    /// folder is removed. A run still alive is recorded as an issue and then
    /// ended, so a failing test leaves nothing behind either.
    func expectNothingLeft(sourceLocation: SourceLocation = #_sourceLocation) async {
        let ended = await eventually(within: .seconds(10)) { self.runsStillRunning.isEmpty }
        if !ended {
            Issue.record(
                "fake helper runs \(runsStillRunning) outlived the test (\(folder.url.lastPathComponent))",
                sourceLocation: sourceLocation)
            endWhatStillRuns()
        }
        folder.remove()
        #expect(!FileManager.default.fileExists(atPath: folder.url.path), sourceLocation: sourceLocation)
    }

    /// Kills every run still alive, after checking that the process id is
    /// still this fake's.
    private func endWhatStillRuns() {
        guard runs > 0 else { return }
        for n in 1...runs {
            letGo(run: n)
            guard let pid = processID(ofRun: n), isThisFake(pid) else { continue }
            // A run the supervisor started leads a process group of its own
            // (its sleep is in it); one started otherwise does not.
            if getpgid(pid) == pid { _ = killpg(pid, SIGKILL) } else { _ = kill(pid, SIGKILL) }
        }
    }

    private func isThisFake(_ pid: pid_t) -> Bool {
        commandLine(of: pid)?.contains(program.path) == true
    }
}

/// The arguments a process was started with, or nil once it is gone (a
/// zombie included) or cannot be read.
func commandLine(of pid: pid_t) -> [String]? {
    var name: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&name, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
    var buffer = [UInt8](repeating: 0, count: size)
    guard sysctl(&name, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
    let argc = buffer.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
    // After the count: the executable's path, padding, then the arguments,
    // each ended by a zero byte.
    let fields = buffer[MemoryLayout<Int32>.size..<size].split(separator: 0, omittingEmptySubsequences: true)
    guard fields.count > argc else { return nil }
    return fields.dropFirst().prefix(argc).map { String(decoding: $0, as: UTF8.self) }
}
