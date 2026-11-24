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

    /// `mac/Tests/StandIns/replies/`: one folder per login provider, one
    /// reply file per reply a detector rule follows (plan HD-8). The detector
    /// tests read them here; the stand-ins play the copy's.
    public static let replies = sourceFolder.appendingPathComponent("replies", isDirectory: true)

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
    /// The copy's reply files, which the stand-ins play.
    public var replies: URL { root.appendingPathComponent("replies", isDirectory: true) }

    /// Writes the scenario the stand-ins follow (see `provider_tool.py`).
    public func write(scenario: StandInScenario) throws {
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        try encoder.encode(scenario).write(to: state.appendingPathComponent("scenario.json"))
    }

    /// The Python script to run with the provider API scenario and a port file.
    public var providerAPI: URL { file("provider_api.py") }

    /// Writes the scenario for the stand-in provider API and returns its URL.
    /// Its requests are logged alongside it, apart from the tool calls.
    @discardableResult
    public func writeProviderAPIScenario(tokens: [String: StandInScenario.TokenDirective]) throws -> URL {
        let folder = state.appendingPathComponent("provider-api", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("scenario.json")
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        try encoder.encode(["tokens": tokens]).write(to: url, options: .atomic)
        return url
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

    /// What one account does at one of its work prompts (plan HD-11). A
    /// work prompt is a build or a review prompt; the answering check's
    /// "ready" prompt is not one. Every directive counts the account's work
    /// prompts and none reads a clock.
    public struct Directive: Encodable, Sendable {
        /// The tool's program: `claude`, `codex`, `agy` or `grok`.
        public var tool: String
        /// The account folder (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`) the
        /// directive applies to; nil for `agy` and `grok`, which have one
        /// sign-in for the Mac, or for a run with no folder.
        public var account: String?
        /// The first work prompt of the account it applies to, 1 first.
        public var onPrompt: Int
        /// The reply file to answer with, under `replies/`, such as
        /// `claude/run-limit-five-hour.json`.
        public var reply: String?
        /// The reset time the reply states is the moment it is played plus
        /// this many seconds.
        public var resetInSeconds: Int?
        /// How many work prompts in a row, from `onPrompt`, get the reply.
        public var times: Int?
        /// Sign the account out before its `onPrompt`-th work prompt.
        public var signOut: Bool?

        /// Answer the account's `onPrompt`-th work prompt with `reply`, and
        /// the `times - 1` after it too; never again.
        public static func reply(
            _ reply: String, tool: String, account: URL?, onPrompt: Int, resetInSeconds: Int? = nil,
            times: Int? = nil
        ) -> Directive {
            Directive(
                tool: tool, account: account?.path, onPrompt: onPrompt, reply: reply,
                resetInSeconds: resetInSeconds, times: times, signOut: nil)
        }

        /// Sign the account out just before its `beforePrompt`-th work prompt.
        public static func signOut(tool: String, account: URL?, beforePrompt: Int) -> Directive {
            Directive(
                tool: tool, account: account?.path, onPrompt: beforePrompt, reply: nil,
                resetInSeconds: nil, times: nil, signOut: true)
        }
    }

    /// How a tool answers usage and version requests for an account (RD-8).
    public struct UsageDirective: Encodable, Sendable {
        public var tool: String
        public var account: String?
        /// An output or session fixture path relative to the stand-ins' replies folder.
        public var reply: String?
        /// A Claude settings fixture path relative to the replies folder.
        public var settings: String?
        /// Age the settings cache when writing the settings fixture.
        public var staleSettings: Bool?
        public var neverAnswers: Bool?
        /// The full text printed by the stand-in's version command.
        public var version: String?
        /// Override the Codex home returned by the session.
        public var codexHome: String?

        public init(
            tool: String, account: URL? = nil, reply: String? = nil, settings: String? = nil,
            staleSettings: Bool? = nil, neverAnswers: Bool? = nil, version: String? = nil, codexHome: URL? = nil
        ) {
            self.tool = tool
            self.account = account?.path
            self.reply = reply
            self.settings = settings
            self.staleSettings = staleSettings
            self.neverAnswers = neverAnswers
            self.version = version
            self.codexHome = codexHome?.path
        }
    }

    /// How the stand-in provider API answers a request with a fake token marker.
    public enum TokenDirective: Encodable, Sendable {
        /// A fixture path relative to the stand-ins' replies folder.
        case reply(String)
        case neverAnswers

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .reply(let file):
                try container.encode(file, forKey: .reply)
            case .neverAnswers:
                try container.encode(true, forKey: .neverAnswers)
            }
        }

        private enum CodingKeys: String, CodingKey {
            case reply, neverAnswers
        }
    }

    /// Round r of review follows `reviews[r]`, then the last entry.
    public var reviews: [Review]
    /// A review does not answer until `state/<gateFile>` exists.
    public var gateFile: String?
    public var builder: Builder
    /// Every account's directives.
    public var directives: [Directive]
    public var usage: [UsageDirective]

    public init(
        reviews: [Review] = [], gateFile: String? = nil, builder: Builder = .evidence,
        directives: [Directive] = [], usage: [UsageDirective] = []
    ) {
        self.reviews = reviews
        self.gateFile = gateFile
        self.builder = builder
        self.directives = directives
        self.usage = usage
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
