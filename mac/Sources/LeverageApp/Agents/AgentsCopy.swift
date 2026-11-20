import Foundation
import LeverageKit

/// The owner-facing sentences of the Agents screen and the Connect sheet
/// (MA-10, MA-12, MA-30, Q-15). A sentence with a `{name}` in it is filled in
/// by `filled(_:)`. The words come from the mockup where it draws them.
enum AgentsCopy: OwnerFacingCopy {
    // The list.
    case loading, empty, emptyNeedsLogin, connect, addLogin
    case roleBuilder, roleReviewer, rolePlanner, roleOrchestrator
    case roleLine, stateBuilding, stateRunning, stateStopped, stateConnectsOnItsOwn, statePaused, stateOff
    case runsOn, defaultModel, defaultEffort, effortNamed, on, off
    case lastAsked, neverAsked
    case chipRunning, chipStopped
    case start, stop, starting, stopping, remove, copyLandingPrompt, copied
    case startFailed, stopFailed
    case removeTitle, removeMessage, removeConfirm, cancel

    // The Connect sheet.
    case connectTitle, modeRunOnLogin, modeOwn, roleLabel, nameLabel, namePlaceholder, nameRequired
    case loginLabel, noLogins, geminiHidden, providerLabel
    case modelLabel, modelHint, effortLabel, effortHint
    case connectButton, connecting
    case tokenTitle, tokenNote, tokenGone, copy
    case landingTitle, landingNote, landingLoading, landingRetry
    case done

    var text: String {
        switch self {
        case .loading: "Loading the agents…"
        case .empty: "No agents yet. Connect one to give it work."
        case .emptyNeedsLogin: "No login has been added yet, so an agent has nothing to run on."
        case .connect: "Connect agent"
        case .addLogin: "Add a login"
        case .roleBuilder: "Builder"
        case .roleReviewer: "Reviewer"
        case .rolePlanner: "Planner"
        case .roleOrchestrator: "Orchestrator"
        case .roleLine: "{role}. {state}"
        case .stateBuilding: "Building {task}."
        case .stateRunning: "Running. Waiting for work."
        case .stateStopped: "Stopped."
        case .stateConnectsOnItsOwn: "Connects on its own."
        case .statePaused: "Paused."
        case .stateOff: "Off."
        case .runsOn: "Runs on {login}."
        case .defaultModel: "Default model"
        case .defaultEffort: "Default effort"
        case .effortNamed: "{effort} effort"
        case .on: "On"
        case .off: "Off"
        case .lastAsked: "Last asked for work {when}."
        case .neverAsked: "Has not asked for work yet."
        case .chipRunning: "Running"
        case .chipStopped: "Stopped"
        case .start: "Start"
        case .stop: "Stop"
        case .starting: "Starting…"
        case .stopping: "Stopping…"
        case .remove: "Remove"
        case .copyLandingPrompt: "Copy landing prompt"
        case .copied: "Copied"
        case .startFailed: "{name} could not start. Check its login in Credentials."
        case .stopFailed: "{name} did not stop. Try again."
        case .removeTitle: "Remove {name}?"
        case .removeMessage: "Its token stops working at once, and anything it is working on goes back to waiting."
        case .removeConfirm: "Remove"
        case .cancel: "Cancel"

        case .connectTitle: "Connect agent"
        case .modeRunOnLogin: "Run it on one of my logins"
        case .modeOwn: "It connects on its own"
        case .roleLabel: "What it does"
        case .nameLabel: "Name"
        case .namePlaceholder: "Claude, Personal"
        case .nameRequired: "Give it a name."
        case .loginLabel: "Login"
        case .noLogins: "No login has been added yet."
        case .geminiHidden: "Gemini logins can't review yet, so they are not listed."
        case .providerLabel: "Which tool is it?"
        case .modelLabel: "Model"
        case .modelHint: "Leave empty to use the tool's own default."
        case .effortLabel: "Effort"
        case .effortHint: "Leave empty to use the tool's own default."
        case .connectButton: "Connect"
        case .connecting: "Connecting…"
        case .tokenTitle: "Its token"
        case .tokenNote: "It will not be shown again."
        case .tokenGone: "This agent was connected already, and its token can't be shown again. Remove it and connect it again."
        case .copy: "Copy"
        case .landingTitle: "Landing prompt"
        case .landingNote: "Paste this into the agent. It tells the agent how to work with leverage and what to confirm with you."
        case .landingLoading: "Getting the landing prompt…"
        case .landingRetry: "Try again"
        case .done: "Done"
        }
    }

    /// The sentence for a role.
    static func role(_ role: SeatRole) -> AgentsCopy {
        switch role {
        case .builder: .roleBuilder
        case .reviewer: .roleReviewer
        case .planner: .rolePlanner
        case .orchestrator: .roleOrchestrator
        }
    }
}
