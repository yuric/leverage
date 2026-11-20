import Foundation

/// The stand-in tools of `mac/Tests/StandIns/` (plan PV-7): the four
/// providers' tools, the stand-in runner, the stand-in installer and archive,
/// and the scripts `SubprocessTests` runs.
///
/// A test never runs the stand-ins where they are checked in: it copies the
/// folder into a temporary folder of its own with `copy(into:)` and points
/// `LEVERAGE_TOOL_DIR` at the copy's `bin`. The copy keeps its state beside
/// itself, in `state/`, so no two tests share it and nothing reaches it
/// through the environment. `provider_tool.py` documents every file.
public enum StandIns {
    /// `mac/Tests/StandIns/`, found from this file's own path (SwiftPM takes
    /// no resources from outside a target's folder).
    public static let sourceFolder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // LeverageTestSupport
        .deletingLastPathComponent()  // Tests
        .appendingPathComponent("StandIns", isDirectory: true)

    /// The four providers' tools, by the name of their program.
    public static let toolNames = ["claude", "codex", "agy", "grok"]

    /// The made-up email and organisation the stand-ins' status output
    /// prints, which a secret scan must never find in a log or the database.
    public static let statusEmail = "standin.owner@example.invalid"
    public static let statusOrganisation = "Stand-in Example Org"

    /// Copies the stand-ins into `folder/StandIns` and returns the copy.
    public static func copy(into folder: URL) throws -> StandInTools {
        let root = folder.appendingPathComponent("StandIns", isDirectory: true)
        let files = FileManager.default
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        for name in try files.contentsOfDirectory(atPath: sourceFolder.path)
        where !["state", "__pycache__"].contains(name) {
            try files.copyItem(
                at: sourceFolder.appendingPathComponent(name),
                to: root.appendingPathComponent(name))
        }
        let tools = StandInTools(root: root)
        // Keep the programs runnable whatever the copy did to their modes.
        for program in toolNames.map(tools.tool) + StandInTools.scripts.map(tools.file) {
            try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: program.path)
        }
        return tools
    }
}

/// One copy of the stand-ins, in a test's own temporary folder.
public struct StandInTools: Sendable {
    static let scripts = [
        "stand_in_runner.sh", "installer.sh", "big_output.sh", "sleeping_grandchild.sh",
    ]

    public let root: URL

    /// The folder `LEVERAGE_TOOL_DIR` points at.
    public var bin: URL { root.appendingPathComponent("bin", isDirectory: true) }
    public var state: URL { root.appendingPathComponent("state", isDirectory: true) }

    /// A provider's stand-in tool: `claude`, `codex`, `agy` or `grok`.
    public func tool(_ name: String) -> URL { bin.appendingPathComponent(name) }

    /// A file at the copy's top level, such as `big_output.sh`.
    public func file(_ name: String) -> URL { root.appendingPathComponent(name) }

    public var runner: URL { file("stand_in_runner.sh") }
    public var installer: URL { file("installer.sh") }
    public var archive: URL { file("standin-tool.tar.gz") }

    /// Writes the scenario the stand-ins follow (see `provider_tool.py`).
    public func write(scenario: StandInScenario) throws {
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        try encoder.encode(scenario).write(to: state.appendingPathComponent("scenario.json"))
    }

    /// Plays the owner signing in: for a tool with an account folder, that
    /// folder; for `agy` and `grok`, or with no folder, the Mac's one sign-in.
    public func signIn(_ tool: String, accountFolder: URL? = nil) throws {
        let mark = markFile(tool, accountFolder: accountFolder)
        try FileManager.default.createDirectory(
            at: mark.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("signed in\n".utf8).write(to: mark)
    }

    public func isSignedIn(_ tool: String, accountFolder: URL? = nil) -> Bool {
        FileManager.default.fileExists(atPath: markFile(tool, accountFolder: accountFolder).path)
    }

    /// Lets a review that waits for its gate file answer.
    public func openGate(_ name: String) throws {
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        try Data().write(to: state.appendingPathComponent(name))
    }

    /// Every run of a provider's stand-in tool so far, oldest first.
    public func calls() throws -> [StandInCall] {
        let log = state.appendingPathComponent("calls.jsonl")
        guard FileManager.default.fileExists(atPath: log.path) else { return [] }
        return try String(contentsOf: log, encoding: .utf8)
            .split(separator: "\n")
            .map { try JSONDecoder().decode(StandInCall.self, from: Data($0.utf8)) }
    }

    /// What each start of the stand-in runner recorded, by process id.
    public func runnerStarts() throws -> [StandInRunnerStart] {
        let folder = state.appendingPathComponent("runner", isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasSuffix(".json") }
            .map { name in
                try JSONDecoder().decode(
                    StandInRunnerStart.self,
                    from: Data(contentsOf: folder.appendingPathComponent(name)))
            }
            .sorted { $0.pid < $1.pid }
    }

    private func markFile(_ tool: String, accountFolder: URL?) -> URL {
        if let accountFolder, ["claude", "codex"].contains(tool) {
            return accountFolder.appendingPathComponent(".standin-signed-in")
        }
        return state.appendingPathComponent("signed-in-\(tool)")
    }
}

/// The script the stand-ins follow.
public struct StandInScenario: Encodable, Sendable {
    public struct Review: Encodable, Sendable {
        /// The criteria numbers this round fails.
        public var fail: [Int]
        public var notes: String?

        public init(fail: [Int] = [], notes: String? = nil) {
            self.fail = fail
            self.notes = notes
        }
    }

    public enum Builder: String, Encodable, Sendable {
        /// Writes the criterion's file and answers its evidence line.
        case evidence
        /// Answers `LEVERAGE-CANNOT:`.
        case cannot
        /// Writes the file and gives no marker line.
        case silent
    }

    /// Round r of review follows `reviews[r]`, then the last entry.
    public var reviews: [Review]
    /// A review does not answer until `state/<gateFile>` exists.
    public var gateFile: String?
    public var builder: Builder

    public init(reviews: [Review] = [], gateFile: String? = nil, builder: Builder = .evidence) {
        self.reviews = reviews
        self.gateFile = gateFile
        self.builder = builder
    }
}

/// One run of a provider's stand-in tool.
public struct StandInCall: Decodable, Sendable {
    public let tool: String
    public let argv: [String]
    public let cwd: String
    public let env: [String: String]
}

/// One start of the stand-in runner.
public struct StandInRunnerStart: Decodable, Sendable {
    public let argv: [String]
    public let env: [String: String]
    public let cwd: String
    public let pid: Int32
    public let childPid: Int32

    enum CodingKeys: String, CodingKey {
        case argv, env, cwd, pid
        case childPid = "child_pid"
    }
}
