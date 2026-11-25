import Foundation
import LeverageKit

/// The owner-facing sentences of the Agents screen and the Connect sheet
/// (MA-10, MA-12, MA-30, Q-15). A sentence with a `{name}` in it is filled in
/// by `filled(_:)`. The words come from the mockup where it draws them.
enum AgentsCopy: OwnerFacingCopy {
    // The list.
    case loading, empty, emptyNeedsLogin, connect, addLogin
    case roleGeneral, roleBuilder, roleReviewer, rolePlanner, roleOrchestrator
    case roleLine, stateBuilding, stateRunning, stateConnectsOnItsOwn, statePaused, stateOff
    case runsOn, defaultModel, defaultEffort, effortNamed, on, off
    case lastAsked, neverAsked
    case chipRunning
    case start, stop, starting, stopping, remove, copied
    case startFailed, stopFailed
    // Pause, Resume and Change (HM-45, HM-51, HE-26, HE-27).
    case stateNotRunning, stateWaitingFor, chipNotRunning, pausedNote
    case pause, resume, change, pausing, resuming, pausedWord
    case changeTitle, changeNote, changeEnabledLabel, turnOffNote, turnOnNote, changeSave, changeSaving
    case removeTitle, removeMessage, removeConfirm, cancel

    // The Connect sheet.
    case connectTitle, modeRunOnLogin, modeOwn, roleLabel, nameLabel, namePlaceholder, nameRequired
    case loginLabel, noLogins, geminiHidden, providerLabel
    case modelLabel, effortLabel, clearEffort, promptModelHint, reportedModel, notReported, notOffered, needsNewerTool
    case permissionHeading, mayWork, mayDeliver, mayCreate, mayList, mayNothing, deliverOffNote
    case strengthLabel, strengthStandard, strengthStronger, strengthStrongest
    case connectionLabel, connectionMCP, connectionHTTP
    case notTestedForChecking
    case connectButton, connecting
    case copy
    case landingTitle, landingNote, landingLoading, landingRetry
    case done

    var text: String {
        switch self {
        case .loading: "Loading the agents…"
        case .empty: "No agents yet. Connect one to give it work."
        case .emptyNeedsLogin: "No login has been added yet, so an agent has nothing to run on."
        case .connect: "Connect agent"
        case .addLogin: "Add a login"
        case .roleGeneral: "General"
        case .roleBuilder: "Builder"
        case .roleReviewer: "Reviewer"
        case .rolePlanner: "Planner"
        case .roleOrchestrator: "Orchestrator"
        case .roleLine: "{role}. {state}"
        case .stateBuilding: "Building {task}."
        case .stateRunning: "Running. Waiting for work."
        case .stateConnectsOnItsOwn: "Connected by prompt."
        case .statePaused: "Paused."
        case .stateOff: "Off."
        case .runsOn: "Runs on {login}."
        case .defaultModel: "The tool's default"
        case .defaultEffort: "Default effort"
        case .effortNamed: "{effort} effort"
        case .on: "On"
        case .off: "Off"
        case .lastAsked: "Last asked for work {when}."
        case .neverAsked: "Has not asked for work yet."
        case .chipRunning: "Running"
        case .start: "Start"
        case .stop: "Stop"
        case .starting: "Starting…"
        case .stopping: "Stopping…"
        case .remove: "Remove"
        case .copied: "Copied"
        case .startFailed: "{name} could not start. Check its login in Credentials."
        case .stopFailed: "{name} did not stop. Try again."
        case .stateNotRunning: "Not running."
        case .stateWaitingFor: "Waiting for {account}."
        case .chipNotRunning: "Not running"
        case .pausedNote:
            "Pausing does not stop its run. It takes no new work, and a task it is on waits. If the pause lasts longer than the agent's time on the task, the task goes back to waiting for any agent."
        case .pause: "Pause"
        case .resume: "Resume"
        case .change: "Change"
        case .pausing: "Pausing…"
        case .resuming: "Resuming…"
        case .pausedWord: "Paused"
        case .changeTitle: "Change {name}"
        case .changeNote: "Changes apply the next time the agent starts a run."
        case .changeEnabledLabel: "Turned on"
        case .turnOffNote: "Turning it off stops its run and sends any task it is building back to waiting."
        case .turnOnNote: "Turning it on does not start it. Choose Start on its row."
        case .changeSave: "Save"
        case .changeSaving: "Saving…"
        case .removeTitle: "Remove {name}?"
        case .removeMessage: "Its token stops working at once, and anything it is working on goes back to waiting."
        case .removeConfirm: "Remove"
        case .cancel: "Cancel"

        case .connectTitle: "Connect agent"
        case .modeRunOnLogin: "Native: run on my login"
        case .modeOwn: "Prompt: paste into any agent"
        case .roleLabel: "What it does"
        case .nameLabel: "Name"
        case .namePlaceholder: "Claude, Personal"
        case .nameRequired: "Give it a name."
        case .loginLabel: "Login"
        case .noLogins: "A Native agent runs on one of your logins. Add a login first, then connect the agent."
        case .geminiHidden: "Gemini logins can't review yet, so they are not listed."
        case .providerLabel: "Which tool is it?"
        case .notTestedForChecking: "Not tested for checking tasks."
        case .modelLabel: "Model"
        case .effortLabel: "Effort"
        case .clearEffort: "Use default effort"
        case .promptModelHint: "The agent tells Leverage its model when it joins."
        case .reportedModel: "Reported by the agent: {settings}"
        case .notReported: "Not reported yet"
        case .notOffered: "{value} (not offered now)"
        case .needsNewerTool: "{value} (needs {tool} {version} or newer)"
        case .permissionHeading: "What this agent may do"
        case .mayWork: "Work on tasks"
        case .mayDeliver: "Deliver tasks"
        case .mayCreate: "Create tasks"
        case .mayList: "May: {permissions}"
        case .mayNothing: "nothing"
        case .deliverOffNote: "It gives back the task it is working on."
        case .strengthLabel: "How strong is its model"
        case .strengthStandard: "Standard"
        case .strengthStronger: "Stronger"
        case .strengthStrongest: "Strongest"
        case .connectionLabel: "How it connects"
        case .connectionMCP: "Through MCP"
        case .connectionHTTP: "By HTTP calls"
        case .connectButton: "Connect"
        case .connecting: "Connecting…"
        case .copy: "Copy"
        case .landingTitle: "Landing prompt"
        case .landingNote: "Paste this into the agent. The prompt contains the agent’s token."
        case .landingLoading: "Getting the landing prompt…"
        case .landingRetry: "Try again"
        case .done: "Done"
        }
    }

    static func connection(_ way: LandingPromptConnection) -> AgentsCopy {
        switch way {
        case .mcp: .connectionMCP
        case .http: .connectionHTTP
        }
    }

    /// The sentence for a role.
    static func role(_ role: SeatRole) -> AgentsCopy {
        switch role {
        case .general: .roleGeneral
        case .builder: .roleBuilder
        case .reviewer: .roleReviewer
        case .planner: .rolePlanner
        case .orchestrator: .roleOrchestrator
        }
    }
}

/// The three strengths the owner can choose (AP-24).
enum AgentStrength: Int, CaseIterable {
    case standard = 1
    case stronger = 2
    case strongest = 3

    var copy: AgentsCopy {
        switch self {
        case .standard: .strengthStandard
        case .stronger: .strengthStronger
        case .strongest: .strengthStrongest
        }
    }
}
