import LeverageKit

/// The owner-facing sentences of the Settings screen, Rules (milestone 4
/// plan RM-1, RD-8, RD-25 to RD-29, RD-32). The words for a rule's moment
/// are the contract's own (`RuleHook.momentName`), not repeated here.
enum RulesCopy: OwnerFacingCopy {
    case title

    // The screen.
    case hint, loading, empty, addRule, change, comesWithLeverage, addedByYou

    // The labels of a row.
    case whenItRuns, appliesTo, checkedBy, ifItFails, wordingOf, turnOn, turnOff

    // Who a rule applies to, who checks it, and what a failure does.
    case scopeAllTasks, scopeCheckerDecides, scopeNamedProjects, scopeActionKinds
    case scopeNamedProjectsList, scopeActionKindsList, scopeNoProjects, scopeUnlistedProject
    case checkerApp, checkerModel
    case onFailBlock, onFailWarn

    // The counts line (RD-26, RD-32).
    case countsNone, countsRanOnce, countsRan, countsAverage, countsUnderSecond
    case countsTokens, countsSpend, countsLetThroughOnce, countsLetThrough

    // The sheet.
    case addTitle, changeTitle, nameLabel, namePlaceholder, instructionLabel, instructionPlaceholder
    case momentLabel, scopeLabel, onFailLabel, numbersLabel
    case parameterMinimumCount, parameterThreshold
    case save, add, cancel, saving, revertToDefault, removeRule, removeAsk, removeKeep

    var text: String {
        switch self {
        case .title: "Rules"
        case .hint: "What leverage checks, and when. A change applies to what is asked after you save it."
        case .loading: "Loading the rules…"
        case .empty: "There are no rules yet."
        case .addRule: "Add a rule"
        case .change: "Change"
        case .comesWithLeverage: "Comes with leverage"
        case .addedByYou: "Added by you"

        case .whenItRuns: "When it runs"
        case .appliesTo: "Applies to"
        case .checkedBy: "Checked by"
        case .ifItFails: "If it fails"
        case .wordingOf: "Wording of {date}"
        case .turnOn: "Turn on {name}"
        case .turnOff: "Turn off {name}"

        case .scopeAllTasks: "Every task"
        case .scopeCheckerDecides: "The agent that checks decides"
        case .scopeNamedProjects: "Tasks in these projects"
        case .scopeActionKinds: "Tasks that end in"
        case .scopeNamedProjectsList: "Tasks in these projects ({name})"
        case .scopeActionKindsList: "Tasks that end in {name}"
        case .scopeNoProjects: "There are no projects to choose."
        case .scopeUnlistedProject: "Project no longer listed"
        case .checkerApp: "leverage checks this itself"
        case .checkerModel: "An agent checks this"
        case .onFailBlock: "Stop the task"
        case .onFailWarn: "Only note it"

        case .countsNone: "Has not run yet"
        case .countsRanOnce: "Ran once"
        case .countsRan: "Ran {count} times"
        case .countsAverage: "average {time}"
        case .countsUnderSecond: "under a second"
        case .countsTokens: "{count} tokens"
        case .countsSpend: "{amount} reported"
        case .countsLetThroughOnce: "let through once"
        case .countsLetThrough: "let through {count} times"

        case .addTitle: "Add a rule"
        case .changeTitle: "Change a rule"
        case .nameLabel: "Name"
        case .namePlaceholder: "What the rule asks for, in a few words"
        case .instructionLabel: "What the agent checks for"
        case .instructionPlaceholder: "Say when a task passes and when it does not."
        case .momentLabel: "When it runs"
        case .scopeLabel: "Applies to"
        case .onFailLabel: "If it fails"
        case .numbersLabel: "Numbers"
        case .parameterMinimumCount: "Fewest acceptance criteria"
        case .parameterThreshold: "Failed reviews before a stronger model"
        case .save: "Save"
        case .add: "Add rule"
        case .cancel: "Cancel"
        case .saving: "Saving…"
        case .revertToDefault: "Go back to the original wording"
        case .removeRule: "Remove this rule"
        case .removeAsk: "Remove this rule? It stops being checked."
        case .removeKeep: "Keep it"
        }
    }

    /// The label of a number an app rule takes, by the name the contract gives it.
    static func parameterLabel(for key: String) -> String {
        switch key {
        case "minimum_count": Self.parameterMinimumCount.text
        case "threshold": Self.parameterThreshold.text
        default: key.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// The words for a kind of scope.
    static func scopeWords(_ kind: RuleScopeKind) -> RulesCopy {
        switch kind {
        case .allTasks: .scopeAllTasks
        case .checkerDecides: .scopeCheckerDecides
        case .namedProjects: .scopeNamedProjects
        case .actionKinds: .scopeActionKinds
        }
    }

    static func scopeDescription(_ scope: RuleScope, projects: [Project]) -> String {
        switch scope.kind {
        case .namedProjects:
            let ids = Set(scope.projectIDs ?? [])
            let names = projects.filter { ids.contains($0.id) && $0.contentDeletedAt == nil }.map(\.name)
            if !names.isEmpty {
                return scopeNamedProjectsList.filled(["name": names.joined(separator: ", ")])
            }
        case .actionKinds:
            let names = (scope.actionKinds ?? []).map { TaskPageCopy.actionKind($0).text }
            if !names.isEmpty {
                return scopeActionKindsList.filled(["name": names.joined(separator: ", ")])
            }
        case .allTasks, .checkerDecides:
            break
        }
        return scopeWords(scope.kind).text
    }
}
