/// Every sentence the owner reads in the app is a case of one copy catalog:
/// an enum conforming to `OwnerFacingCopy`. `CopyCatalogs.all` lists every
/// catalog, so a test can check every sentence against the PRD's
/// plain-language rule.
protocol OwnerFacingCopy: CaseIterable, Sendable {
    /// The sentence as the owner reads it.
    var text: String { get }
}

extension OwnerFacingCopy {
    /// Every sentence of this catalog.
    static var allTexts: [String] { allCases.map(\.text) }
}

enum CopyCatalogs {
    /// Every copy catalog of the app, one per screen folder.
    static let all: [any OwnerFacingCopy.Type] = [
        ShellCopy.self,
        SignInCopy.self,
        BoardCopy.self,
        AddTaskCopy.self,
        TaskPageCopy.self,
        AgentsCopy.self,
        CredentialsCopy.self,
        NeedsYouCopy.self,
        HandoffCopy.self,
        RulesCopy.self,
    ]
}
