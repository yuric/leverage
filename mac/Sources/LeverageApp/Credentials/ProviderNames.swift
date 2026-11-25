import LeverageKit

/// The names of the providers and of their tools as the owner reads them.
/// The four logins come from `ProviderCatalog` and the names below cover
/// API tokens as well.
enum ProviderNames {
    /// The four providers a login can be added for, in the order the mockup lists them.
    static let logins: [Provider] = ModelCatalog.providers.map(\.provider)

    /// "Claude", "Codex", "Gemini", "Grok".
    static func name(_ provider: Provider) -> String {
        if let entry = ProviderCatalog.entry(for: provider.rawValue) { return entry.displayName }
        switch provider {
        case .claudeApi: return "Claude API"
        case .openaiApi: return "OpenAI API"
        case .geminiApi: return "Gemini API"
        case .grokApi: return "Grok API"
        case .openrouter: return "OpenRouter"
        case .claude, .codex, .gemini, .grok: return provider.rawValue
        }
    }

    /// "Claude, Personal": an account as the owner reads it, never by its email or plan.
    static func account(_ credential: Credential) -> String {
        "\(name(credential.provider)), \(credential.name)"
    }

    /// The model the provider's tool names as its default on this Mac, which
    /// Add credential sends (HE-5); nil where the tool names none (Codex and
    /// Antigravity), so the credential keeps no model.
    static func defaultModel(_ provider: Provider) -> String? {
        ProviderCatalog.entry(for: provider.rawValue)?.defaultModel?.value
    }

    /// The tool that runs the provider's agents: "Claude Code", "Codex", "Antigravity", "Grok Build".
    static func tool(_ provider: Provider) -> String {
        ProviderCatalog.entry(for: provider.rawValue)?.toolDisplayName ?? name(provider)
    }
}
