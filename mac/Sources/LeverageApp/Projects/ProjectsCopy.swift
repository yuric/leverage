import LeverageKit

enum ProjectsCopy: OwnerFacingCopy {
    case title, loading, empty, deletedProject, deletedContent, back
    case newProject, name, goal, budget, budgetInUSD, noLimit, reported, spent
    case pause, resume, paused, pausedForBudget, changeBudget
    case brief, emptyBrief, editBrief, addEntry, entryKind, entryText, moveUp, moveDown, removeEntry
    case rule, decision, lesson, save, create, cancel
    case deleteContent, confirmDelete, deleteExplanation

    var text: String {
        switch self {
        case .title: "Projects"
        case .loading: "Loading projects…"
        case .empty: "No projects yet."
        case .deletedProject: "Deleted project"
        case .deletedContent: "This project's content was deleted. Its task history and timing are still available."
        case .back: "Back to projects"
        case .newProject: "New project"
        case .name: "Name"
        case .goal: "Goal"
        case .budget: "Budget"
        case .budgetInUSD: "Budget in US dollars"
        case .noLimit: "No limit"
        case .reported: "{amount} reported"
        case .spent: "Spent"
        case .pause: "Pause project"
        case .resume: "Resume project"
        case .paused: "Paused"
        case .pausedForBudget: "Paused at its budget"
        case .changeBudget: "Change budget"
        case .brief: "Brief"
        case .emptyBrief: "No rules, decisions or lessons yet."
        case .editBrief: "Edit brief"
        case .addEntry: "Add an entry"
        case .entryKind: "Kind of entry"
        case .entryText: "Entry text"
        case .moveUp: "Move entry up"
        case .moveDown: "Move entry down"
        case .removeEntry: "Remove entry"
        case .rule: "Rule"
        case .decision: "Decision"
        case .lesson: "Lesson"
        case .save: "Save"
        case .create: "Create project"
        case .cancel: "Cancel"
        case .deleteContent: "Delete content"
        case .confirmDelete: "Delete this project's content?"
        case .deleteExplanation: "This deletes the project brief and the content of all its tasks. The task history and timing stay."
        }
    }

    static func kind(_ kind: BriefEntryKind) -> Self {
        switch kind {
        case .rule: .rule
        case .decision: .decision
        case .lesson: .lesson
        }
    }

    static func projectName(_ project: Project) -> String {
        project.name.isEmpty ? deletedProject.text : project.name
    }
}
