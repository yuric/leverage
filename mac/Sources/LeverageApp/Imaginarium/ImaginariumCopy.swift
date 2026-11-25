import LeverageKit

enum ImaginariumCopy: OwnerFacingCopy {
    case catalogUnavailable, headline, searchPrompts, surpriseMe, all, noMatchingPrompts
    case timeEstimate, needsImageTool, tryIt, tryPrompt, copied, copyPrompt, copyNamedPrompt
    case close, makeItYours, doneWhen, reviewCriterion, prompt
    case doneEditing, editPrompt, fillInsKeepEdits, undoEdits
    case goesToProject, projectUnavailable, sendToReady, saveToIdeas, saving, checking, tryAgain
    case sentToReady, savedToIdeas, savedToBacklog, seeOnBoard, keepBrowsing

    var text: String {
        switch self {
        case .catalogUnavailable: "The prompt catalog is unavailable"
        case .headline: "Make something on your Mac"
        case .searchPrompts: "Search prompts"
        case .surpriseMe: "Surprise me"
        case .all: "All"
        case .noMatchingPrompts: "No matching prompts"
        case .timeEstimate: "About {minutes} min"
        case .needsImageTool: "Needs an agent with an image tool"
        case .tryIt: "Try it"
        case .tryPrompt: "Try {title}"
        case .copied: "Copied"
        case .copyPrompt: "Copy prompt"
        case .copyNamedPrompt: "Copy {title} prompt"
        case .close: "Close"
        case .makeItYours: "Make it yours"
        case .doneWhen: "Done when"
        case .reviewCriterion: "A second agent reviews the work"
        case .prompt: "Prompt"
        case .doneEditing: "Done editing"
        case .editPrompt: "Edit prompt"
        case .fillInsKeepEdits: "Fill-ins leave your edited prompt as written."
        case .undoEdits: "Undo my edits"
        case .goesToProject: "Goes to {project}"
        case .projectUnavailable: "The Imaginarium project is unavailable."
        case .sendToReady: "Send to Ready"
        case .saveToIdeas: "Save to Ideas"
        case .saving: "Saving task…"
        case .checking: "Waiting for a rule check…"
        case .tryAgain: "Try again"
        case .sentToReady: "Sent to Ready"
        case .savedToIdeas: "Saved to Ideas"
        case .savedToBacklog: "Saved to Backlog"
        case .seeOnBoard: "See it on the board"
        case .keepBrowsing: "Keep browsing"
        }
    }

    static func estimate(_ minutes: Int) -> String {
        timeEstimate.filled(["minutes": String(minutes)])
    }

    static func savedTitle(_ state: TaskState) -> Self {
        switch state {
        case .ready: .sentToReady
        case .ideas: .savedToIdeas
        default: .savedToBacklog
        }
    }
}
