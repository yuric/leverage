import LeverageKit

/// The owner-facing sentences of the Add task form (MA-13, MA-15, MA-16, HM-48)
/// and of the same form on a task's page, where it changes the contract
/// (HM-49). The words come from the mockup.
enum AddTaskCopy: OwnerFacingCopy {
    case sheetTitle
    case titleLabel, titlePlaceholder
    case goalLabel, goalPlaceholder, goalHint
    case criteriaLabel, criteriaPlaceholder, criteriaHint, criteriaHintRuleOn
    case detailsLabel, detailsPlaceholder
    case projectLabel, noProject, actionsLabel
    case actionPublish, actionPay, actionSend, actionDelete
    case priorityLabel, priorityLow, priorityNormal, priorityHigh
    case workLabel, workPlaceholder, workHint
    case footnote, footnoteProviderRule
    case cancel, save, saving, saveAsIdea, ideaKeepsNoCriteria
    case changeTaskTitle, saveChanges, saveAndSend, editWarning, editWarningNoAgent
    case savedNotSent

    /// The last criterion of every task: the independent review (PRD Terms).
    case reviewCriterion

    static func actionKind(_ kind: ActionKind) -> Self { .actionPublish }

    var text: String {
        switch self {
        case .sheetTitle: "Add task"
        case .titleLabel: "What should get done?"
        case .titlePlaceholder: "Fix the totals on the invoice page"
        case .goalLabel: "What is the goal?"
        case .goalPlaceholder: "The totals match the lines, to the cent"
        case .goalHint: "Leave this empty to use the title."
        case .criteriaLabel: "How will you know it is done?"
        case .criteriaPlaceholder: "Totals match the sum of the lines to the cent"
        case .criteriaHint: "One thing to check on each line."
        case .criteriaHintRuleOn: "Leave this empty and the task waits in Backlog until you fill it in."
        case .detailsLabel: "Who is it for, and what must it include or avoid?"
        case .detailsPlaceholder: "Optional"
        case .projectLabel, .noProject, .actionsLabel, .actionPublish, .actionPay, .actionSend, .actionDelete: ""
        case .priorityLabel: "Priority"
        case .priorityLow: "Low"
        case .priorityNormal: "Normal"
        case .priorityHigh: "High"
        case .workLabel: "Where the work is"
        case .workPlaceholder: "A folder on this Mac, or a link"
        case .workHint: "Optional. leverage does not open it. Don't put sign-in details here."
        case .footnote: "An agent that did not build it reviews the work before it counts as done."
        case .footnoteProviderRule: "An agent from another provider reviews the work before it counts as done."
        case .cancel: "Cancel"
        case .save: "Save task"
        case .saving: "Saving…"
        case .saveAsIdea: "Save as an idea"
        case .ideaKeepsNoCriteria:
            "An idea keeps the title, the goal and the details. Say what done looks like when you move it to Backlog."
        case .changeTaskTitle: "Change the task"
        case .saveChanges: "Save"
        case .saveAndSend: "Save and send to agents"
        case .editWarning:
            "The agent stops and the task goes back to Backlog. What has passed stays passed if you leave it as it is."
        case .editWarningNoAgent:
            "The task goes back to Backlog. What has passed stays passed if you leave it as it is."
        case .savedNotSent:
            "The task is saved in Backlog but was not sent to agents yet. Press Save task to send it again."
        case .reviewCriterion: "An independent reviewer agrees."
        }
    }
}
