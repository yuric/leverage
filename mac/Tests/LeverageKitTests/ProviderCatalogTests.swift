import Foundation
import Testing

@testable import LeverageKit

/// The provider catalog (plan PV-1 to PV-5, CL-10). Its facts were taken on
/// this Mac on 2026-11-19 by WP2a's step 0; the evidence level of each is
/// asserted so that a change to a fact is also a change to how it is known.
@Suite("ProviderCatalog")
struct ProviderCatalogTests {
    private func entry(_ id: String) throws -> ProviderEntry {
        try #require(ProviderCatalog.entry(for: id))
    }

    @Test("lists the registry's four login providers, in its order")
    func matchesRegistry() throws {
        let data = try Data(contentsOf: RegistryDecodingTests.registryURL)
        let registry = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let providers = try #require(registry?["credential_providers"] as? [[String: Any]])
        let logins = providers.filter { $0["kind"] as? String == "login" }.compactMap { $0["provider"] as? String }

        #expect(ProviderCatalog.entries.map(\.id) == logins)
        #expect(logins == ["claude", "codex", "gemini", "grok"])
    }

    @Test("token entries match the registry's token providers in order")
    func tokensMatchRegistry() throws {
        let data = try Data(contentsOf: RegistryDecodingTests.registryURL)
        let registry = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let providers = try #require(registry?["credential_providers"] as? [[String: Any]])
        let tokens = providers.filter { $0["kind"] as? String == "api_token" }.compactMap { $0["provider"] as? String }

        #expect(ProviderCatalog.tokenEntries.map(\.provider.rawValue) == tokens)
        #expect(tokens == ["claude_api", "openai_api", "gemini_api", "grok_api", "openrouter"])
        for provider in Provider.allCases where provider.kind == .login {
            #expect(ProviderCatalog.tokenEntry(for: provider) == nil)
        }
    }

    @Test("each token check has a documented HTTPS endpoint and sends the token in a header", arguments: [
        (Provider.claudeApi, "Claude API", "https://api.anthropic.com/v1/models", "Authorization", "Bearer"),
        (Provider.openaiApi, "OpenAI API", "https://api.openai.com/v1/models", "Authorization", "Bearer"),
        (Provider.geminiApi, "Gemini API", "https://generativelanguage.googleapis.com/v1beta/models", "x-goog-api-key", ""),
        (Provider.grokApi, "Grok API", "https://api.x.ai/v1/api-key", "Authorization", "Bearer"),
        (Provider.openrouter, "OpenRouter", "https://openrouter.ai/api/v1/key", "Authorization", "Bearer"),
    ])
    func tokenCheck(provider: Provider, name: String, address: String, header: String, scheme: String) throws {
        let entry = try #require(ProviderCatalog.tokenEntry(for: provider))
        #expect(entry.provider == provider)
        #expect(entry.displayName == name)
        #expect(entry.url.value.absoluteString == address)
        #expect(entry.url.evidence == .documented)
        #expect(entry.method == Evidenced("GET", .documented))
        #expect(entry.prd == .prd)
        let url = entry.url.value
        #expect(url.scheme == "https")
        #expect(url.user == nil && url.password == nil && url.query == nil && url.fragment == nil)
        let authentication = TokenAuthentication(header: header, scheme: scheme.isEmpty ? nil : scheme)
        #expect(entry.authentication == Evidenced(authentication, .documented))
        let extra = provider == .claudeApi ? ["anthropic-version": "2026-10-21"] : [:]
        #expect(entry.extraHeaders == Evidenced(extra, .documented))
        #expect(ProviderCatalog.loginUsage(for: provider) == nil)
    }

    @Test("Claude's usage report and Codex's app-server retain evidence for each fact")
    func loginCommands() throws {
        let claude = try #require(ProviderCatalog.loginUsage(for: .claude))
        #expect(claude.arguments == Evidenced(["-p", "/usage", "--output-format", "json"], .prd))
        #expect(claude.details.contains(Evidenced("cachedUsageUtilization.utilization.cedar_ember", .prd)))
        #expect(claude.details.contains(Evidenced(".claude.json in CLAUDE_CONFIG_DIR", .probe)))
        #expect(claude.details.contains(Evidenced("The entry is kept in that file", .unverified)))

        let codex = try #require(ProviderCatalog.loginUsage(for: .codex))
        #expect(codex.arguments == Evidenced(["app-server"], .help))
        #expect(codex.details.contains(Evidenced("account/rateLimits/read", .schema)))
        #expect(codex.details.contains(Evidenced("account/usage/read", .schema)))
        #expect(codex.details.contains(Evidenced("One JSON object per line", .unverified)))
    }

    @Test("Gemini's usage screen and Grok's help are descriptive sources", arguments: [
        (Provider.gemini, "Antigravity interactive /usage", Evidence.documented),
        (Provider.grok, "grok usage --json", Evidence.help),
    ])
    func loginSources(provider: Provider, source: String, evidence: Evidence) throws {
        let usage = try #require(ProviderCatalog.loginUsage(for: provider))
        #expect(usage.source == Evidenced(source, evidence))
        #expect(usage.arguments == Evidenced(nil, .help))
    }

    @Test("names: the provider as the app shows it, the tool and its program")
    func names() {
        #expect(ProviderCatalog.entries.map(\.displayName) == ["Claude", "Codex", "Gemini", "Grok"])
        #expect(ProviderCatalog.entries.map(\.toolDisplayName)
            == ["Claude Code", "Codex", "Antigravity", "Grok Build"])
        #expect(ProviderCatalog.entries.map(\.toolName) == ["claude", "codex", "agy", "grok"])
    }

    @Test("every tool's version command ran under the allow-list")
    func versions() {
        for entry in ProviderCatalog.entries {
            #expect(entry.version == Evidenced(["--version"], .probe), "\(entry.id)")
        }
    }

    @Test("Claude: its folder variable, USER in its environment, status by loggedIn")
    func claude() throws {
        let claude = try entry("claude")
        #expect(claude.accountFolderVariable == Evidenced("CLAUDE_CONFIG_DIR", .probe))
        #expect(claude.environment == Evidenced(["USER"], .probe))
        #expect(claude.status == Evidenced(
            StatusCheck(arguments: ["auth", "status"], reading: .jsonField("loggedIn")), .probe))
        #expect(claude.signIn == Evidenced(
            SignIn(arguments: ["auth", "login"], opensBrowserItself: .unknown, readsFromTerminal: .unknown),
            .help))
        #expect(claude.installer == Evidenced(
            Installer(kind: .script(shell: "/bin/bash"), url: URL(string: "https://claude.ai/install.sh")!,
                      allowedHosts: ["claude.ai"]),
            .documented))
    }

    @Test("Codex: its folder variable, status by its recorded \"Not logged in\", OpenAI's script")
    func codex() throws {
        let codex = try entry("codex")
        #expect(codex.accountFolderVariable == Evidenced("CODEX_HOME", .probe))
        #expect(codex.environment == Evidenced([], .probe))
        #expect(codex.status == Evidenced(
            StatusCheck(arguments: ["login", "status"], reading: .signedOutText("Not logged in")), .probe))
        #expect(codex.signIn.value.arguments == ["login"])
        #expect(codex.signIn.evidence == .help)
        #expect(codex.installer == Evidenced(
            Installer(kind: .script(shell: "/bin/sh"), url: URL(string: "https://chatgpt.com/codex/install.sh")!,
                      allowedHosts: ["chatgpt.com"]),
            .documented))
    }

    @Test("Gemini: one sign-in for the Mac, no status or sign-in command")
    func gemini() throws {
        let gemini = try entry("gemini")
        // The PRD says Antigravity keeps one sign-in for the Mac, and
        // `agy --help` lists no account variable: help, not probe.
        #expect(gemini.accountFolderVariable == Evidenced(nil, .help))
        #expect(gemini.environment == Evidenced([], .probe))
        #expect(gemini.status == Evidenced(StatusCheck(arguments: nil, reading: .testPrompt), .help))
        #expect(gemini.signIn == Evidenced(
            SignIn(arguments: nil, opensBrowserItself: .unknown, readsFromTerminal: .unknown), .help))
        #expect(gemini.installer.value?.url.absoluteString == "https://antigravity.google/cli/install.sh")
        #expect(gemini.installer.evidence == .documented)
    }

    @Test("Grok: treated as one sign-in for the Mac, status from its text, no installer")
    func grok() throws {
        let grok = try entry("grok")
        #expect(grok.accountFolderVariable == Evidenced(nil, .unverified))
        #expect(grok.environment == Evidenced([], .unverified))
        #expect(grok.status == Evidenced(
            StatusCheck(arguments: ["models"], reading: .signedOutText("You are not authenticated.")),
            .probe))
        #expect(grok.signIn == Evidenced(
            SignIn(arguments: ["login", "--oauth"], opensBrowserItself: .unknown, readsFromTerminal: .unknown),
            .help))
        #expect(grok.installer == Evidenced(nil, .unverified))
    }

    @Test("an installer address must be HTTPS on a host its entry lists", arguments: [
        ("https://claude.ai/install.sh", true),
        ("http://claude.ai/install.sh", false),
        ("https://claude.ai.example.invalid/install.sh", false),
        ("https://evil.example.invalid/install.sh", false),
        ("https://user@claude.ai/install.sh", false),
        ("https://claude.ai:8443/install.sh", false),
        ("file:///tmp/install.sh", false),
    ])
    func installerHosts(address: String, permitted: Bool) throws {
        let installer = try #require(try entry("claude").installer.value)
        #expect(installer.permits(URL(string: address)!) == permitted)
    }

    @Test("a tool gets PATH, HOME, TMPDIR, LANG, its own extras and its folder, and no leverage token")
    func toolEnvironment() throws {
        let parent = [
            "PATH": "/somewhere/else", "HOME": "/Users/someone", "TMPDIR": "/tmp/x/", "LANG": "en_US.UTF-8",
            "USER": "someone", "LOGNAME": "someone", "SHELL": "/bin/zsh",
            "LEVERAGE_SEAT_TOKEN": "lvs_madeUp", "LEVERAGE_HELPER_TOKEN": "lvh_madeUp",
            "LEVERAGE_API_URL": "http://127.0.0.1:47130",
        ]
        let claude = ProviderCatalog.toolEnvironment(
            for: try entry("claude"), from: parent, toolFolder: "/opt/tools/claude",
            accountFolder: "/support/accounts/abc", supportFolder: "/support")

        #expect(claude == [
            "PATH": "/opt/tools/claude:/support/tools/claude:/Users/someone/.local/bin:/opt/homebrew/bin"
                + ":/usr/local/bin:/Users/someone/.grok/bin:/usr/bin:/bin",
            "HOME": "/Users/someone", "TMPDIR": "/tmp/x/", "LANG": "en_US.UTF-8", "USER": "someone",
            "CLAUDE_CONFIG_DIR": "/support/accounts/abc",
        ])

        let gemini = ProviderCatalog.toolEnvironment(
            for: try entry("gemini"), from: parent, toolFolder: "/Users/someone/.local/bin",
            accountFolder: nil, supportFolder: "/support")
        #expect(Set(gemini.keys) == ["PATH", "HOME", "TMPDIR", "LANG"])
        #expect(gemini["PATH"] == "/Users/someone/.local/bin:/support/tools/gemini:/opt/homebrew/bin"
            + ":/usr/local/bin:/Users/someone/.grok/bin:/usr/bin:/bin")
    }

    @Test("with LEVERAGE_TOOL_DIR set, that folder is the only one searched")
    func toolDirOnly() {
        #expect(ProviderCatalog.searchFolders(
            for: "codex", home: "/Users/someone", supportFolder: "/support", toolDir: "/tmp/standins/bin")
            == ["/tmp/standins/bin"])
        #expect(ProviderCatalog.searchFolders(
            for: "codex", home: "/Users/someone", supportFolder: "/support", toolDir: nil)
            == ["/support/tools/codex", "/Users/someone/.local/bin", "/opt/homebrew/bin",
                "/usr/local/bin", "/Users/someone/.grok/bin"])
    }

    @Test("no evidence level below probe is called proven")
    func evidenceNames() {
        #expect(Evidence.allCases.map(\.rawValue)
            == ["probe", "probe (full environment)", "help", "documented", "unverified", "schema", "PRD"])
        #expect(Evidence.allCases.filter(\.isProven) == [.probe])
    }

    @Test("the default model each tool itself named, with how it is known; none for Codex and Antigravity")
    func defaultModel() throws {
        // Claude's is the one key of `modelUsage` in the reply to the
        // inventory's "ready" prompt, run with no --model; Grok's is the
        // "Default model" line of `grok models`. Both ran on this Mac on
        // 2026-11-19 with the agent's whole environment (plan HE-5, §0 fact 30).
        #expect(try entry("claude").defaultModel == Evidenced("claude-opus-5-5", .probeFullEnvironment))
        #expect(try entry("grok").defaultModel == Evidenced("grok-4.6", .probeFullEnvironment))
        #expect(try entry("codex").defaultModel == nil)
        #expect(try entry("gemini").defaultModel == nil)
    }

    @Test("Claude and Antigravity take an effort; Codex and Grok are given none (their drivers pass none)")
    func effort() {
        #expect(ProviderCatalog.takesEffort(.claude))
        #expect(ProviderCatalog.takesEffort(.gemini))
        #expect(!ProviderCatalog.takesEffort(.codex))
        #expect(!ProviderCatalog.takesEffort(.grok))
    }
}
