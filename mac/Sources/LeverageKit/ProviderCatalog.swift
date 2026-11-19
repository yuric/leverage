import Foundation

/// How a fact in the catalog is known (plan PV-1). Nothing below `probe` is
/// called proven anywhere.
public enum Evidence: String, CaseIterable, Sendable {
    /// Ran on this Mac on 2026-11-19 under the tool's allow-listed
    /// environment (CL-10).
    case probe = "probe"
    /// Ran on this Mac, but with the whole environment of the agent that
    /// ran it, not the allow-list.
    case probeFullEnvironment = "probe (full environment)"
    /// Read in the tool's own `--help` on this Mac; never run.
    case help
    /// Read in the vendor's own documentation; never run.
    case documented
    /// None of these.
    case unverified

    public var isProven: Bool { self == .probe }
}

/// A fact and how it is known.
public struct Evidenced<Value: Equatable & Sendable>: Equatable, Sendable {
    public let value: Value
    public let evidence: Evidence

    public init(_ value: Value, _ evidence: Evidence) {
        self.value = value
        self.evidence = evidence
    }
}

/// Something step 0 could not settle from the tool's help.
public enum Knowledge: Equatable, Sendable {
    case yes, no, unknown
}

/// How the helper tells whether an account is signed in (plan PV-3).
public struct StatusCheck: Equatable, Sendable {
    public enum Reading: Equatable, Sendable {
        /// The output is JSON; this Boolean field says signed in. Nothing
        /// else of the output is kept or logged.
        case jsonField(String)
        /// Exit code 0 means signed in.
        case exitCode
        /// Signed out when the output contains this text (the exit code is
        /// 0 either way).
        case signedOutText(String)
        /// There is no status command: the answering check (a test prompt)
        /// is the sign-in check.
        case testPrompt
    }

    /// The arguments after the program; nil when there is no command.
    public let arguments: [String]?
    public let reading: Reading

    public init(arguments: [String]?, reading: Reading) {
        self.arguments = arguments
        self.reading = reading
    }
}

/// The provider's own sign-in command (plan PV-4). The helper runs it with
/// the account's folder variable and standard input closed.
public struct SignIn: Equatable, Sendable {
    /// The arguments after the program; nil when the tool has none.
    public let arguments: [String]?
    /// Whether it opens the browser by itself.
    public let opensBrowserItself: Knowledge
    /// Whether it reads anything from a terminal, which the helper never
    /// gives it.
    public let readsFromTerminal: Knowledge

    public init(arguments: [String]?, opensBrowserItself: Knowledge, readsFromTerminal: Knowledge) {
        self.arguments = arguments
        self.opensBrowserItself = opensBrowserItself
        self.readsFromTerminal = readsFromTerminal
    }
}

/// Where a tool is installed from with no terminal (plan PV-5).
public struct Installer: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// The vendor's installer script, downloaded and run with `shell`.
        case script(shell: String)
        /// A release archive, unpacked into `<support folder>/tools/<provider>/`;
        /// `program` is the file inside it that becomes the tool.
        case archive(program: String)
    }

    public let kind: Kind
    public let url: URL
    /// The only hosts an address may name.
    public let allowedHosts: [String]

    public init(kind: Kind, url: URL, allowedHosts: [String]) {
        self.kind = kind
        self.url = url
        self.allowedHosts = allowedHosts
    }

    /// True for an HTTPS address on a listed host, with no user and no
    /// port of its own. `ToolInstaller` refuses every other address.
    public func permits(_ address: URL) -> Bool {
        guard address.scheme?.lowercased() == "https",
              let host = address.host?.lowercased(),
              address.user == nil, address.password == nil, address.port == nil else {
            return false
        }
        return allowedHosts.contains(host)
    }
}

/// One login provider (plan §2.2).
public struct ProviderEntry: Equatable, Sendable {
    /// The registry's `credential_providers` name.
    public let id: String
    /// The provider as the app names it.
    public let displayName: String
    /// The provider's tool, as its vendor names it.
    public let toolDisplayName: String
    /// The tool's program.
    public let toolName: String
    /// The variable that selects an account's settings folder; nil for a
    /// provider with one sign-in for the Mac.
    public let accountFolderVariable: Evidenced<String?>
    /// The arguments that print the version.
    public let version: Evidenced<[String]>
    public let status: Evidenced<StatusCheck>
    public let signIn: Evidenced<SignIn>
    /// Nil where no documented source needs no terminal.
    public let installer: Evidenced<Installer?>
    /// The variables the tool gets besides `ProviderCatalog.baseEnvironment`
    /// and its account folder variable, each without a secret (CL-10).
    public let environment: Evidenced<[String]>
}

/// Per login provider: names, commands, installer and environment, each
/// with its evidence level. The facts were taken on this Mac on 2026-11-19
/// (WP2a's step 0, with only harmless commands: versions, statuses, help
/// and one "ready" prompt per signed-in tool, under the allow-list).
public enum ProviderCatalog {
    /// What every provider's tool gets (CL-10); `PATH` is built, not passed.
    public static let baseEnvironment = [
        EnvironmentKeys.path, EnvironmentKeys.home, EnvironmentKeys.tmpdir, EnvironmentKeys.lang,
    ]

    public static let entries: [ProviderEntry] = [
        ProviderEntry(
            id: "claude", displayName: "Claude", toolDisplayName: "Claude Code", toolName: "claude",
            accountFolderVariable: Evidenced("CLAUDE_CONFIG_DIR", .probe),
            version: Evidenced(["--version"], .probe),
            status: Evidenced(StatusCheck(arguments: ["auth", "status"], reading: .jsonField("loggedIn")), .probe),
            // `claude auth login --help`: "Sign in to your Anthropic account";
            // it does not say whether it opens the browser or reads input.
            signIn: Evidenced(
                SignIn(arguments: ["auth", "login"], opensBrowserItself: .unknown, readsFromTerminal: .unknown),
                .help),
            installer: Evidenced(
                Installer(
                    kind: .script(shell: "/bin/bash"), url: URL(string: "https://claude.ai/install.sh")!,
                    allowedHosts: ["claude.ai"]),
                .documented),
            // Without USER, `claude auth status` answers signed out on this
            // Mac: the tool finds its login by the user's name.
            environment: Evidenced([EnvironmentKeys.user], .probe)),
        ProviderEntry(
            id: "codex", displayName: "Codex", toolDisplayName: "Codex", toolName: "codex",
            accountFolderVariable: Evidenced("CODEX_HOME", .probe),
            version: Evidenced(["--version"], .probe),
            status: Evidenced(StatusCheck(arguments: ["login", "status"], reading: .exitCode), .probe),
            // `codex login --help` lists --device-auth, and --with-api-key and
            // --with-access-token, which read standard input; not what the
            // plain command does.
            signIn: Evidenced(
                SignIn(arguments: ["login"], opensBrowserItself: .unknown, readsFromTerminal: .unknown), .help),
            // OpenAI's README and CLI page: `curl -fsSL
            // https://chatgpt.com/codex/install.sh | sh`. The script downloads
            // from releases.openai.com, falling back to GitHub Releases.
            installer: Evidenced(
                Installer(
                    kind: .script(shell: "/bin/sh"), url: URL(string: "https://chatgpt.com/codex/install.sh")!,
                    allowedHosts: ["chatgpt.com"]),
                .documented),
            environment: Evidenced([], .probe)),
        ProviderEntry(
            id: "gemini", displayName: "Gemini", toolDisplayName: "Antigravity", toolName: "agy",
            accountFolderVariable: Evidenced(nil, .probe),
            version: Evidenced(["--version"], .probe),
            // `agy --help` lists no status and no sign-in command.
            status: Evidenced(StatusCheck(arguments: nil, reading: .testPrompt), .help),
            signIn: Evidenced(
                SignIn(arguments: nil, opensBrowserItself: .unknown, readsFromTerminal: .unknown), .help),
            installer: Evidenced(
                Installer(
                    kind: .script(shell: "/bin/bash"),
                    url: URL(string: "https://antigravity.google/cli/install.sh")!,
                    allowedHosts: ["antigravity.google"]),
                .documented),
            environment: Evidenced([], .probe)),
        ProviderEntry(
            id: "grok", displayName: "Grok", toolDisplayName: "Grok Build", toolName: "grok",
            // How Grok Build keeps an account is not known; it is treated as
            // one sign-in for the Mac (CL-21).
            accountFolderVariable: Evidenced(nil, .unverified),
            version: Evidenced(["--version"], .probe),
            status: Evidenced(
                StatusCheck(arguments: ["models"], reading: .signedOutText("You are not authenticated.")),
                .probe),
            // `grok login --help`: "--oauth  Force browser (loopback) login
            // instead of device-code authentication".
            signIn: Evidenced(
                SignIn(arguments: ["login", "--oauth"], opensBrowserItself: .unknown, readsFromTerminal: .unknown),
                .help),
            // The vendor's pages answered 403 and 404 again on 2026-11-19.
            installer: Evidenced(nil, .unverified),
            // Grok is not signed in on this Mac, so no prompt has run.
            environment: Evidenced([], .unverified)),
    ]

    public static func entry(for id: String) -> ProviderEntry? {
        entries.first { $0.id == id }
    }

    /// Where a provider's tool is looked for, in order (PV-3): only
    /// `toolDir` when it is set (the stand-ins in tests); otherwise where
    /// leverage installs an archive, then the folders the vendors' installers
    /// and package managers use.
    public static func searchFolders(
        for id: String, home: String, supportFolder: String, toolDir: String?
    ) -> [String] {
        if let toolDir, !toolDir.isEmpty { return [toolDir] }
        return [
            "\(supportFolder)/tools/\(id)", "\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin",
            "\(home)/.grok/bin",
        ]
    }

    /// The whole environment of a provider's tool (CL-10): `PATH` is the
    /// tool's own folder, the search folders and `/usr/bin:/bin`; `HOME`,
    /// `TMPDIR`, `LANG` and the entry's own extras come from `parent`; the
    /// account folder variable is set when the entry has one and `accountFolder`
    /// is given. Nothing else of `parent` passes, so no leverage token does.
    public static func toolEnvironment(
        for entry: ProviderEntry,
        from parent: [String: String],
        toolFolder: String,
        accountFolder: String?,
        supportFolder: String,
        toolDir: String? = nil
    ) -> [String: String] {
        let home = parent[EnvironmentKeys.home] ?? ""
        var folders: [String] = []
        for folder in [toolFolder]
            + searchFolders(for: entry.id, home: home, supportFolder: supportFolder, toolDir: toolDir)
            + ["/usr/bin", "/bin"] where !folders.contains(folder) {
            folders.append(folder)
        }
        var setting = [EnvironmentKeys.path: folders.joined(separator: ":")]
        if let variable = entry.accountFolderVariable.value, let accountFolder {
            setting[variable] = accountFolder
        }
        return Subprocess.environment(
            allowing: baseEnvironment.filter { $0 != EnvironmentKeys.path } + entry.environment.value,
            from: parent,
            setting: setting)
    }
}
