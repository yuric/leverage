/// The owner-facing sentences of the Add task form (MA-13, MA-15, MA-16) and of
/// the same form on a Backlog task's page. The words come from the mockup.
enum AddTaskCopy: OwnerFacingCopy {
    case sheetTitle
    case titleLabel, titlePlaceholder
    case goalLabel, goalPlaceholder, goalHint
    case criteriaLabel, criteriaPlaceholder, criteriaHint
    case detailsLabel, detailsPlaceholder
    case priorityLabel, priorityLow, priorityNormal, priorityHigh
    case workLabel, workPlaceholder, workHint
    case footnote
    case cancel, save, saving
    case savedNotSent

    /// The last criterion of every task: the independent review (PRD Terms).
    case reviewCriterion

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
        case .detailsLabel: "Who is it for, and what must it include or avoid?"
        case .detailsPlaceholder: "Optional"
        case .priorityLabel: "Priority"
        case .priorityLow: "Low"
        case .priorityNormal: "Normal"
        case .priorityHigh: "High"
        case .workLabel: "Where the work is"
        case .workPlaceholder: "A folder on this Mac, or a link"
        case .workHint: "Optional. leverage does not open it. Don't put sign-in details here."
        case .footnote: "An agent that did not build it reviews the work before it counts as done."
        case .cancel: "Cancel"
        case .save: "Save task"
        case .saving: "Saving…"
        case .savedNotSent:
            "The task is saved in Backlog but was not sent to agents yet. Press Save task to send it again."
        case .reviewCriterion: "An independent reviewer agrees."
        }
    }
}
