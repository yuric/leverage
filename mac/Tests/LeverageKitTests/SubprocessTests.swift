import Foundation
import LeverageTestSupport
import Testing

@testable import LeverageKit

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// `Subprocess` is the one way the Mac side runs a child process (plan
/// CL-10, CL-23). These tests run only the system's own programs and the
/// stand-in scripts, in folders of their own.
@Suite("Subprocess")
struct SubprocessTests {
    private func standIns() throws -> (TemporaryFolder, StandInTools) {
        let folder = try TemporaryFolder(prefix: "subprocess-test")
        return (folder, try StandIns.copy(into: folder.url))
    }

    @Test("the child sees exactly the environment it is given, never the parent's")
    func allowListOnly() async throws {
        setenv("LEVERAGE_SUBPROCESS_TEST_MARKER", "lvh_madeUpMadeUpMadeUpMadeUp", 1)
        let environment = Subprocess.environment(
            allowing: ["PATH", "HOME", "NOT_SET_ANYWHERE"],
            from: ProcessInfo.processInfo.environment,
            setting: ["LEVERAGE_PROVIDER": "claude"])

        let result = try await Subprocess.run(.init(
            executable: "/usr/bin/env", arguments: [], environment: environment))

        let seen = String(decoding: result.standardOutput, as: UTF8.self)
            .split(separator: "\n")
            .compactMap { $0.split(separator: "=", maxSplits: 1).first.map(String.init) }
        #expect(Set(seen) == ["PATH", "HOME", "LEVERAGE_PROVIDER"])
        #expect(result.termination == .exited(0))
    }

    @Test("an allow-list keeps only the names it lists, and the values it sets win")
    func environmentFromAllowList() {
        let built = Subprocess.environment(
            allowing: ["HOME", "LANG"],
            from: ["HOME": "/Users/someone", "LEVERAGE_HELPER_TOKEN": "lvh_x", "PATH": "/bin"],
            setting: ["PATH": "/usr/bin:/bin"])
        #expect(built == ["HOME": "/Users/someone", "PATH": "/usr/bin:/bin"])
    }

    @Test("standard input is closed: a program that reads it ends at once")
    func standardInputClosed() async throws {
        let result = try await Subprocess.run(.init(
            executable: "/bin/cat", arguments: [], environment: [:],
            timeLimit: .seconds(20)))
        #expect(result.termination == .exited(0))
        #expect(result.standardOutput.isEmpty)
        #expect(result.endedBy == nil)
    }

    @Test("both outputs are read while the child runs: 1 MiB on each comes back whole")
    func largeOutputs() async throws {
        let (folder, tools) = try standIns()
        defer { folder.remove() }

        let result = try await Subprocess.run(.init(
            executable: tools.file("big_output.sh").path, arguments: [],
            environment: ["PATH": "/usr/bin:/bin"], timeLimit: .seconds(60)))

        #expect(result.termination == .exited(0))
        #expect(result.standardOutput.count == 1_048_576)
        #expect(result.standardError.count == 1_048_576)
        #expect(Set(result.standardOutput) == [UInt8(ascii: "a")])
        #expect(Set(result.standardError) == [UInt8(ascii: "b")])
    }

    @Test("the exit code, the working folder and the arguments are the child's")
    func exitCodeFolderArguments() async throws {
        let folder = try TemporaryFolder(prefix: "subprocess-cwd")
        defer { folder.remove() }

        let result = try await Subprocess.run(.init(
            executable: "/bin/sh", arguments: ["-c", "pwd; echo \"$1\"; exit 3", "sh", "one two"],
            environment: ["PATH": "/usr/bin:/bin"], workingDirectory: folder.url.path))

        #expect(result.termination == .exited(3))
        #expect(String(decoding: result.standardOutput, as: UTF8.self)
            == "\(folder.url.path)\none two\n")
    }

    @Test("the time limit ends the child and the sleeping grandchild it started")
    func timeLimitEndsTheGroup() async throws {
        let (folder, tools) = try standIns()
        defer { folder.remove() }
        let pidFile = folder.path("grandchild.pid")
        let started = Date()

        let result = try await Subprocess.run(.init(
            executable: tools.file("sleeping_grandchild.sh").path, arguments: [pidFile.path],
            environment: ["PATH": "/usr/bin:/bin"], timeLimit: .seconds(2)))

        #expect(result.endedBy == .timeLimit)
        #expect(result.termination == .signaled(SIGTERM))
        #expect(Date().timeIntervalSince(started) < 15)
        let grandchild = try #require(try readPID(pidFile))
        #expect(await gone(grandchild))
    }

    @Test("a stop asks first, then forces a child that ignores the request")
    func stopForcesAfterGrace() async throws {
        let child = try Subprocess.start(.init(
            executable: "/bin/sh", arguments: ["-c", "trap '' TERM; echo up; sleep 600"],
            environment: ["PATH": "/usr/bin:/bin"], gracePeriod: .milliseconds(500)))
        try await Task.sleep(for: .milliseconds(300))

        child.stop()
        let result = await child.wait()

        #expect(result.endedBy == .stop)
        #expect(result.termination == .signaled(SIGKILL))
        #expect(await gone(child.processID))
    }

    @Test("a stop ends the child and the sleeping grandchild it started")
    func stopEndsTheGroup() async throws {
        let (folder, tools) = try standIns()
        defer { folder.remove() }
        let pidFile = folder.path("grandchild.pid")

        let child = try Subprocess.start(.init(
            executable: tools.file("sleeping_grandchild.sh").path, arguments: [pidFile.path],
            environment: ["PATH": "/usr/bin:/bin"]))
        let grandchild = try await waitForPID(pidFile)
        child.stop()
        let result = await child.wait()

        #expect(result.endedBy == .stop)
        #expect(await gone(grandchild))
        #expect(await gone(child.processID))
    }

    @Test("what the child leaves running in its group when it exits is ended")
    func leftoversAreEnded() async throws {
        let started = Date()
        let result = try await Subprocess.run(.init(
            executable: "/bin/sh", arguments: ["-c", "sleep 600 & echo $!"],
            environment: ["PATH": "/usr/bin:/bin"], timeLimit: .seconds(60)))

        #expect(result.termination == .exited(0))
        #expect(result.endedBy == nil)
        #expect(Date().timeIntervalSince(started) < 15)
        let text = String(decoding: result.standardOutput, as: UTF8.self)
        let leftover = try #require(Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(await gone(leftover))
    }

    @Test("cancelling the task that waits stops the child")
    func cancellationStops() async throws {
        let task = Task {
            try await Subprocess.run(.init(
                executable: "/bin/sleep", arguments: ["600"], environment: [:]))
        }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        let result = try await task.value
        #expect(result.endedBy == .stop)
    }

    @Test("a relative or missing program is refused before anything starts")
    func refusedPrograms() {
        #expect(throws: SubprocessError.notAbsolute("sh")) {
            try Subprocess.start(.init(executable: "sh", arguments: [], environment: [:]))
        }
        #expect(throws: SubprocessError.notExecutable("/no/such/program")) {
            try Subprocess.start(.init(
                executable: "/no/such/program", arguments: [], environment: [:]))
        }
    }

    @Test("output past the limit is dropped and the result says so")
    func outputLimit() async throws {
        let result = try await Subprocess.run(.init(
            executable: "/bin/sh", arguments: ["-c", "head -c 5000 /dev/zero"],
            environment: ["PATH": "/usr/bin:/bin"], maximumOutputBytes: 1000))
        #expect(result.standardOutput.count == 1000)
        #expect(result.outputTruncated)
    }
}

private func readPID(_ file: URL) throws -> Int32? {
    Int32(try String(contentsOf: file, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines))
}

private func waitForPID(_ file: URL) async throws -> Int32 {
    for _ in 0..<200 {
        if let pid = try? readPID(file) { return pid }
        try await Task.sleep(for: .milliseconds(50))
    }
    throw CocoaError(.fileReadNoSuchFile)
}

/// True once no process has this id. It looks for up to five seconds, so an
/// orphan that its new parent has not reaped yet is given time.
private func gone(_ pid: Int32) async -> Bool {
    for _ in 0..<100 {
        if kill(pid, 0) != 0 && errno == ESRCH { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return false
}
