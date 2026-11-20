/// The owner-facing sentences of the Settings screen, Rules (milestone 4
/// plan RM-1, RD-8, RD-25 to RD-29). The words for a rule's moment are the
/// contract's own (`RuleHook.momentName`), not repeated here.
enum RulesCopy: OwnerFacingCopy {
    case title

    // The screen.
    case hint, loading, empty, addRule, edit, comesWithLeverage, addedByYou

    // The labels of a row.
    case whenItRuns, appliesTo, checkedBy, ifItFails, wordingOf, turnedOn, turnedOff

    // Who a rule applies to, and who checks it, and what a failure does.
    case scopeAllTasks, scopeCheckerDecides, scopeNamedProjects, scopeActionKinds
    case checkerApp, checkerModel
    case onFailBlock, onFailWarn

    // A rule whose effect is not built yet (RD-8).
    case notActing

    // The counts line (RD-26, RD-32).
    case countsNone, countsRanOnce, countsRan, countsAverage, countsUnderSecond
    case countsTokens, countsSpend, countsLetThroughOnce, countsLetThrough

    // The editor.
    case addTitle, editTitle, nameLabel, namePlaceholder, instructionLabel, instructionPlaceholder
    case momentLabel, scopeLabel, onFailLabel, parametersLabel
    case parameterMinimumCount, parameterThreshold
    case save, add, cancel, saving, revertToDefault, removeRule, removeAsk, removeConfirm

    var text: String {
        switch self {
        case .title: "Rules"
        default: ""
        }
    }
}
