import Foundation
import LeverageKit

/// The owner-facing sentences of the board and its cards (MA-1, MA-29). The
/// words come from the mockup where it draws them. A sentence with a `{name}`
/// in it is filled in by `filled(_:)`.
enum BoardCopy: OwnerFacingCopy {
    // Lane headings.
    case laneIdeas, laneBacklog, laneBlocked, laneReady, laneInProgress, laneDone, laneCancelled
    case emptyLane, showCancelled, loading
    case projectFilter, agentFilter, allAgents, selectedProject, selectedAgent

    // A card's status line.
    case lineNotStarted, lineNeedsDetails, lineWaitingForAgent, lineBuilding, lineReviewing, lineFinished
    case lineCancelled, linePaused, anAgent, lineCheckingDetails
    case lineWrappingUp, lineWaitingForItsAgent, lineWaitingForStrongerAgent

    // A card's chip for the state it is in.
    case chipNeedsDetails, chipNew, chipInReview, chipDone, chipCancelled, chipCheckingDetails, chipBeingChecked

    // A card's chip for what a task waits on.
    case chipHasQuestion, chipNeedsApproval, chipNeedsAccess, chipOverBudget, chipProjectPaused, chipCheckFailed
    case chipSentBack, chipActionStopped, chipNeedsLook, chipEveryAgentTurnedAway, chipCheckedTooManyTimes, chipPausedByYou, chipAgentPaused
    case chipNoLoginLeft, chipLoginSignedOut

    // A card's note.
    case noteNoReviewer, noteWaitingForAccount, noteWaitingForAccountNoTime, noteAccountSignedOut, anAccount
    case noteCheckCouldNotRun, noteEveryAgentTurnedAway, noteCheckedTooManyTimes
    case noteQuestion, noteApproval, noteAccess, noteBudget, noteProjectPaused, noteActionStopped, noteActionUnconfirmed
    case noteOtherProvidersTooWeak

    var text: String {
        switch self {
        case .laneIdeas: "Ideas"
        case .laneBacklog: "Backlog"
        case .laneBlocked: "Blocked"
        case .laneReady: "Ready"
        case .laneInProgress: "In progress"
        case .laneDone: "Done"
        case .laneCancelled: "Cancelled"
        case .emptyLane: "Nothing here"
        case .showCancelled: "Show cancelled"
        case .loading: "Loading the board…"
        case .projectFilter: "Project"
        case .agentFilter: "Agent"
        case .allAgents: "All agents"
        case .selectedProject: "Selected project"
        case .selectedAgent: "Selected agent"

        case .lineNotStarted: "Not started yet"
        case .lineNeedsDetails: "Say what done looks like to send it to an agent"
        case .lineWaitingForAgent: "Waiting for a free agent"
        case .lineBuilding: "{agent} is building"
        case .lineReviewing: "{agent}'s work is being reviewed"
        case .lineFinished: "Reviewed and finished"
        case .lineCancelled: "Cancelled"
        case .linePaused: "Paused, was {lane}"
        case .anAgent: "An agent"
        case .lineCheckingDetails: "Waiting for the check to finish"
        case .lineWrappingUp: "Wrapping up"
        case .lineWaitingForItsAgent: "Waiting for its agent"
        case .lineWaitingForStrongerAgent: "Waiting for a stronger agent"

        case .chipNeedsDetails: "Needs details"
        case .chipNew: "New"
        case .chipInReview: "In review"
        case .chipDone: "Done"
        case .chipCancelled: "Cancelled"
        case .chipCheckingDetails: "Checking the details"
        case .chipBeingChecked: "Being checked"

        case .chipHasQuestion: "Has a question"
        case .chipNeedsApproval: "Needs approval"
        case .chipNeedsAccess: "Needs access"
        case .chipOverBudget: "Over budget"
        case .chipProjectPaused: "Project paused"
        case .chipCheckFailed: "A check could not run"
        case .chipSentBack: "Sent back too many times"
        case .chipActionStopped: "Action stopped"
        case .chipNeedsLook: "Needs a look"
        case .chipEveryAgentTurnedAway: "Every agent was turned away"
        case .chipCheckedTooManyTimes: "Checked too many times"
        case .chipPausedByYou: "Paused by you"
        case .chipAgentPaused: "Agent paused"
        case .chipNoLoginLeft: "No login left"
        case .chipLoginSignedOut: "Login signed out"

        case .noteNoReviewer: "No reviewer agent is connected. Connect one in Agents."
        case .noteWaitingForAccount: "Waiting for {account}, which resets at {time}."
        case .noteWaitingForAccountNoTime: "Waiting for {account}. It did not say when it is available again."
        case .noteAccountSignedOut: "{account} is signed out. Sign in again to continue."
        case .anAccount: "an account"
        case .noteCheckCouldNotRun:
            "A check could not run on this task. Open it to run the check again or let it through once."
        case .noteEveryAgentTurnedAway:
            "A check turned away every agent that tried to take this task. Open it to see why."
        case .noteCheckedTooManyTimes:
            "A check ran on this work too many times. Open the task to let it through once or to change the details."
        case .noteQuestion: "An agent is waiting for your answer."
        case .noteApproval: "Something is ready to go out and needs your approval."
        case .noteAccess: "An agent needs you to give it access before it can continue."
        case .noteBudget: "This task reached its spending limit."
        case .noteProjectPaused: "This task is waiting for its project to resume."
        case .noteActionStopped: "Something that was to go out was stopped."
        case .noteActionUnconfirmed: "Check whether what was meant to go out happened."
        case .noteOtherProvidersTooWeak: "Accounts of other providers are not strong enough for this task"
        }
    }

    /// The sentence for a hold's reason as a chip. A task in Backlog whose
    /// contract is incomplete already says so with its own chip.
    static func chip(for reason: HoldReason) -> BoardCopy? {
        switch reason {
        case .ownerQuestion: .chipHasQuestion
        case .ownerApproval: .chipNeedsApproval
        case .access: .chipNeedsAccess
        case .budget: .chipOverBudget
        case .projectPaused: .chipProjectPaused
        case .contractIncomplete: nil
        case .checkError: .chipCheckFailed
        case .roundsExceeded: .chipSentBack
        case .actionStopped: .chipActionStopped
        case .actionUnconfirmed: .chipNeedsLook
        case .claimGateFailed: .chipEveryAgentTurnedAway
        case .rerunLimit: .chipCheckedTooManyTimes
        case .ownerHold: .chipPausedByYou
        case .seatPaused: .chipAgentPaused
        case .credentialLimit: .chipNoLoginLeft
        case .credentialSignedOut: .chipLoginSignedOut
        }
    }

    /// The sentence under a card explaining what the task waits for.
    static func note(for reason: HoldReason) -> BoardCopy? {
        switch reason {
        case .ownerQuestion: .noteQuestion
        case .ownerApproval: .noteApproval
        case .access: .noteAccess
        case .budget: .noteBudget
        case .projectPaused: .noteProjectPaused
        case .actionStopped: .noteActionStopped
        case .actionUnconfirmed: .noteActionUnconfirmed
        case .checkError: .noteCheckCouldNotRun
        case .claimGateFailed: .noteEveryAgentTurnedAway
        case .rerunLimit: .noteCheckedTooManyTimes
        default: nil
        }
    }
}

extension OwnerFacingCopy {
    /// This sentence with each `{name}` replaced by its value.
    func filled(_ values: [String: String]) -> String {
        values.reduce(text) { $0.replacingOccurrences(of: "{\($1.key)}", with: $1.value) }
    }
}
