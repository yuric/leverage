import Foundation
import LeverageKit
import LeverageTestSupport

@testable import LeverageAppServices

#if canImport(Darwin)
import Darwin
#endif

// What the app services tests share: a fake `docker` and a fake `open` that
// the test writes into a temporary folder of its own, a fake helper program,
// a process runner that records what it was asked to run, and a wait.
// Nothing here can reach the real Docker of the Mac the tests run on: the
// supervisor is given only the temporary folder to search.

/// Writes an executable shell script.
func writeScript(_ url: URL, _ text: String) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
}

/// One call the fake `docker` or the fake `open` received.
struct RecordedCall: Equatable {
    var arguments: [String]
    var workingDirectory: String
    var environment: [String: String]
}

/// The shell lines that record a call in `<root>/calls/<n>`: the arguments
/// one per line, the working folder, and the environment. `env` in a shell
/// script also shows the variables the shell sets itself (PWD, OLDPWD,
/// SHLVL, _), which no parent gave it, so they are left out.
private func recordingLines(root: String, name: String) -> String {
    """
    calls='\(root)/calls'
    mkdir -p "$calls"
    n=$(ls "$calls" | wc -l | tr -d ' ')
    rec="$calls/$(printf '%04d' $((n + 1)))-\(name)"
    {
      for a in "$@"; do printf 'arg:%s\\n' "$a"; done
      printf 'cwd:%s\\n' "$(pwd -P)"
      env | grep -v -E '^(PWD|OLDPWD|SHLVL|_)=' | sed 's/^/env:/'
    } > "$rec"
    """
}

/// A fake Docker installation in a temporary folder: `bin/docker` and
/// `tools/open`, driven by marker files under `state/`.
final class FakeDocker: @unchecked Sendable {
    let folder: TemporaryFolder
    var root: URL { folder.url }
    var binFolder: URL { root.appendingPathComponent("bin") }
    var docker: URL { binFolder.appendingPathComponent("docker") }
    var openProgram: URL { root.appendingPathComponent("tools/open") }
    var home: URL { root.appendingPathComponent("home") }
    var supportFolder: URL { root.appendingPathComponent("support") }
    var composeSource: URL { root.appendingPathComponent("bundle/compose.yaml") }

    /// `withDocker: false` leaves the `bin` folder empty.
    init(withDocker: Bool = true) throws {
        folder = try TemporaryFolder(prefix: "leverage-services")
        let path = folder.url.path
        try FileManager.default.createDirectory(
            at: folder.url.appendingPathComponent("state"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: binFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: composeSource.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("name: leverage\nservices: {}\n".utf8).write(to: composeSource)
        if withDocker {
            try writeScript(docker, """
                #!/bin/sh
                \(recordingLines(root: path, name: "docker"))
                state='\(path)/state'
                case "$1" in
                  info)
                    [ -f "$state/engine-running" ] && { echo 29.0.0-made-up; exit 0; }
                    echo "Cannot connect to the Docker daemon" >&2; exit 1 ;;
                  image)
                    [ -f "$state/image-present" ] && { echo sha256:made-up; exit 0; }
                    echo "Error: No such image" >&2; exit 1 ;;
                  volume)
                    [ -f "$state/volume-present" ] && { echo '[{"Name":"made-up"}]'; exit 0; }
                    echo "Error response from daemon: get made-up: no such volume" >&2; exit 1 ;;
                  compose)
                    [ -f .env ] || { echo "no .env here" >&2; exit 5; }
                    [ -f "$state/compose-fails" ] && { echo "compose up failed, made up" >&2; exit 1; }
                    touch "$state/compose-up"; exit 0 ;;
                esac
                exit 2
                """)
        }
        try writeScript(openProgram, """
            #!/bin/sh
            \(recordingLines(root: path, name: "open"))
            [ -f '\(path)/state/docker-starts-when-opened' ] && touch '\(path)/state/engine-running'
            exit 0
            """)
    }

    func set(_ marker: String, _ on: Bool = true) {
        let url = root.appendingPathComponent("state/\(marker)")
        if on {
            FileManager.default.createFile(atPath: url.path, contents: Data())
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func isSet(_ marker: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent("state/\(marker)").path)
    }

    /// Every call recorded, in order, with the program's name.
    func calls() -> [(program: String, call: RecordedCall)] {
        let folder = root.appendingPathComponent("calls")
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
        return names.map { name in
            let text = (try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)) ?? ""
            var call = RecordedCall(arguments: [], workingDirectory: "", environment: [:])
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                if line.hasPrefix("arg:") {
                    call.arguments.append(String(line.dropFirst(4)))
                } else if line.hasPrefix("cwd:") {
                    call.workingDirectory = String(line.dropFirst(4))
                } else if line.hasPrefix("env:") {
                    let pair = line.dropFirst(4)
                    if let equals = pair.firstIndex(of: "=") {
                        call.environment[String(pair[..<equals])] = String(pair[pair.index(after: equals)...])
                    }
                }
            }
            return (String(name.split(separator: "-").last ?? ""), call)
        }
    }

    func dockerCalls() -> [RecordedCall] { calls().filter { $0.program == "docker" }.map(\.call) }
    func openCalls() -> [RecordedCall] { calls().filter { $0.program == "open" }.map(\.call) }
}

/// A process runner that records every program it was asked to run, then
/// runs it for real.
final class RecordingRunner: ProcessRunning, @unchecked Sendable {
    let executables = Locked<[String]>([])

    func run(_ request: SubprocessRequest) async throws -> SubprocessResult {
        executables.update { $0.append(request.executable) }
        return try await SystemProcessRunner().run(request)
    }
}

/// Records every path the locator asked about, and answers with the real
/// file system.
final class RecordingProbe: @unchecked Sendable {
    let paths = Locked<[String]>([])

    var probe: @Sendable (String) -> Bool {
        { [paths] path in
            paths.update { $0.append(path) }
            return DockerLocator.fileIsExecutable(path)
        }
    }
}

/// Asks `condition` again every 20 milliseconds until it holds or the time
/// (times the run's patience) is up; answers whether it held.
func eventually(
    within timeout: Duration = .seconds(45), _ condition: () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + Patience.scaled(timeout)
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}

/// Every regular file under `folder`, read as text.
func textOfEveryFile(under folder: URL) -> [String: String] {
    var found: [String: String] = [:]
    guard let walker = FileManager.default.enumerator(atPath: folder.path) else { return found }
    for case let relative as String in walker {
        let path = folder.appendingPathComponent(relative).path
        var isFolder: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isFolder), !isFolder.boolValue,
           let data = FileManager.default.contents(atPath: path) {
            found[relative] = String(decoding: data, as: UTF8.self)
        }
    }
    return found
}

/// The permission bits of a file or folder.
func mode(of url: URL) -> Int {
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes?[.posixPermissions] as? NSNumber)?.intValue ?? -1
}
