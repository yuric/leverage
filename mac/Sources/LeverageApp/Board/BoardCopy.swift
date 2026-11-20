import Foundation
import LeverageKit

/// The owner-facing sentences of the board and its cards (MA-1, MA-29). The
/// words come from the mockup where it draws them. A sentence with a `{name}`
/// in it is filled in by `filled(_:)`.
enum BoardCopy: OwnerFacingCopy {
    // Lane headings.
    case laneIdeas, laneBacklog, laneBlocked, laneReady, laneInProgress, laneDone, laneCancelled
    case emptyLane, showCancelled, loading

    // A card's status line.
    case lineNotStarted, lineNeedsDetails, lineWaitingForAgent, lineBuilding, lineReviewing, lineFinished
    case lineCancelled, linePaused, anAgent

    // A card's chip for the state it is in.
    case chipNeedsDetails, chipNew, chipInReview, chipDone, chipCancelled

    // A card's chip for what a task waits on.
    case chipHasQuestion, chipNeedsApproval, chipNeedsAccess, chipOverBudget, chipProjectPaused, chipCheckFailed
    case chipSentBack, chipActionStopped, chipNeedsLook, chipNoAgentCanTake, chipPausedByYou, chipAgentPaused
    case chipNoLoginLeft, chipLoginSignedOut

    // A card's note.
    case noteNoReviewer, noteWaitingForAccount, noteWaitingForAccountNoTime, noteAccountSignedOut, anAccount

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

        case .lineNotStarted: "Not started yet"
        case .lineNeedsDetails: "Say what done looks like to send it to an agent"
        case .lineWaitingForAgent: "Waiting for a free agent"
        case .lineBuilding: "{agent} is building"
        case .lineReviewing: "{agent}'s work is being reviewed"
        case .lineFinished: "Reviewed and finished"
        case .lineCancelled: "Cancelled"
        case .linePaused: "Paused, was {lane}"
        case .anAgent: "An agent"

        case .chipNeedsDetails: "Needs details"
        case .chipNew: "New"
        case .chipInReview: "In review"
        case .chipDone: "Done"
        case .chipCancelled: "Cancelled"

        case .chipHasQuestion: "Has a question"
        case .chipNeedsApproval: "Needs approval"
        case .chipNeedsAccess: "Needs access"
        case .chipOverBudget: "Over budget"
        case .chipProjectPaused: "Project paused"
        case .chipCheckFailed: "A check could not run"
        case .chipSentBack: "Sent back too many times"
        case .chipActionStopped: "Action stopped"
        case .chipNeedsLook: "Needs a look"
        case .chipNoAgentCanTake: "No agent can take it"
        case .chipPausedByYou: "Paused by you"
        case .chipAgentPaused: "Agent paused"
        case .chipNoLoginLeft: "No login left"
        case .chipLoginSignedOut: "Login signed out"

        case .noteNoReviewer: "No reviewer agent is connected. Connect one in Agents."
        case .noteWaitingForAccount: "Not yet"
        case .noteWaitingForAccountNoTime: "Not yet"
        case .noteAccountSignedOut: "Not yet"
        case .anAccount: "Not yet"
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
        case .claimGateFailed: .chipNoAgentCanTake
        case .rerunLimit: .chipNeedsLook
        case .ownerHold: .chipPausedByYou
        case .seatPaused: .chipAgentPaused
        case .credentialLimit: .chipNoLoginLeft
        case .credentialSignedOut: .chipLoginSignedOut
        }
    }
}

extension OwnerFacingCopy {
    /// This sentence with each `{name}` replaced by its value.
    func filled(_ values: [String: String]) -> String {
        values.reduce(text) { $0.replacingOccurrences(of: "{\($1.key)}", with: $1.value) }
    }
}
