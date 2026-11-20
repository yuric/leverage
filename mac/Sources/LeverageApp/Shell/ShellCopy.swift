import Foundation
import LeverageKit

/// The owner-facing sentences of the window around the screens: the pane,
/// the toolbar, the health line, the start-up screens, and one sentence for
/// each refusal and each transport error (MA-19), which every screen uses.
enum ShellCopy: OwnerFacingCopy {
    // The app and its window.
    case appName
    case tabBoard, tabNeedsYou, tabAgents, tabCredentials, tabHandoff, tabSettings
    case addTask, backToBoard, signOut

    // The health line at the foot of the pane (MA-23).
    case healthChecking, healthRunning, healthLate, healthAgentsStopped, healthUnreachable
    case healthBackupLate, healthNoOrchestrator, healthOrchestratorOffline
    case tryAgain

    // The screens before the app is ready (PK-3).
    case startingTitle, startingBody
    case dockerMissingTitle, dockerMissingBody, getDockerDesktop, checkAgain
    case dockerStartingTitle, dockerStartingBody
    case dockerNotStartingTitle, dockerNotStartingBody
    case imageMissingTitle, imageMissingBody
    case serverFailedTitle, serverFailedBody
    case cannotReachTitle, cannotReachBody

    // One sentence for each refusal code (MA-19, MA-28).
    case refusalLeaseExpired, refusalTaskCancelled, refusalNotHolder, refusalForbidden, refusalInvalidState
    case refusalPending, refusalOnHold, refusalBriefingNotAcknowledged, refusalBriefingChanged
    case refusalCriteriaIncomplete, refusalBlockedByRule, refusalCredentialInUse, refusalDuplicateName
    case refusalNotEligible

    // One sentence for each transport error.
    case transportMalformed, transportUnauthenticated, transportNotFound, transportKeyReused, transportInvalid

    // Anything else.
    case cannotReach, somethingWentWrong

    var text: String {
        switch self {
        case .appName: "leverage"
        case .tabBoard: "Board"
        case .tabNeedsYou: "Needs you"
        case .tabAgents: "Agents"
        case .tabCredentials: "Credentials"
        case .tabHandoff: "Handoff"
        case .tabSettings: ""
        case .addTask: "Add task"
        case .backToBoard: "Back to the board"
        case .signOut: "Sign out"

        case .healthChecking: "Checking…"
        case .healthRunning: "System is running"
        case .healthLate: "Background work is late"
        case .healthAgentsStopped: "Agents are not running on this Mac"
        case .healthUnreachable: "Can't reach leverage on this Mac"
        case .healthBackupLate: "The daily backup is late"
        case .healthNoOrchestrator: ""
        case .healthOrchestratorOffline: ""
        case .tryAgain: "Try again"

        case .startingTitle: "Starting leverage"
        case .startingBody: "Getting the server ready on this Mac. This takes a few seconds."
        case .dockerMissingTitle: "leverage needs Docker Desktop"
        case .dockerMissingBody:
            "leverage keeps your work in a small server that runs in Docker Desktop on this Mac. Install Docker Desktop, open it once, then check again."
        case .getDockerDesktop: "Get Docker Desktop"
        case .checkAgain: "Check again"
        case .dockerStartingTitle: "Starting Docker Desktop"
        case .dockerStartingBody: "This can take a minute. leverage opens by itself when Docker Desktop is ready."
        case .dockerNotStartingTitle: "Docker Desktop did not start"
        case .dockerNotStartingBody:
            "Open Docker Desktop yourself and wait until it says it is running, then check again."
        case .imageMissingTitle: "This copy of leverage was not built on this Mac."
        case .imageMissingBody: "The server it needs is not in Docker on this Mac. Build the app again on this Mac, then open it."
        case .serverFailedTitle: "leverage could not start"
        case .serverFailedBody: "Something stopped the server from starting. Check that Docker Desktop is running, then try again."
        case .cannotReachTitle: "Can't reach leverage on this Mac"
        case .cannotReachBody: "The server did not answer. Check that Docker Desktop is running, then try again."

        case .refusalLeaseExpired: "The agent stopped responding, so the task went back to waiting."
        case .refusalTaskCancelled: "That task was cancelled."
        case .refusalNotHolder: "That task is with another agent."
        case .refusalForbidden: "That is not allowed."
        case .refusalInvalidState: "That can't be done to the task as it is now."
        case .refusalPending: "That is still being worked on. Check again in a moment."
        case .refusalOnHold: "That task is paused."
        case .refusalBriefingNotAcknowledged: "The agent has not read its briefing yet."
        case .refusalBriefingChanged: "The task changed after the agent read it."
        case .refusalCriteriaIncomplete: "Some of what the task asks for is not done yet."
        case .refusalBlockedByRule: "A rule stops that."
        case .refusalCredentialInUse: "An agent is using that login. Remove the agent first."
        case .refusalDuplicateName: "That name is already used. Pick another."
        case .refusalNotEligible: "That agent can't take this task."

        case .transportMalformed: "That request was not understood. Try again."
        case .transportUnauthenticated: "Your sign-in ended. Sign in again."
        case .transportNotFound: "That is no longer there."
        case .transportKeyReused: "That was already sent with different details. Try again."
        case .transportInvalid: "Something in that is not valid. Check it and try again."

        case .cannotReach: "Can't reach leverage on this Mac. Check that it is running, then try again."
        case .somethingWentWrong: "Something went wrong. Try again."
        }
    }

    /// The sentence for a refusal code.
    static func refusal(_ code: RefusalCode) -> ShellCopy {
        switch code {
        case .leaseExpired: .refusalLeaseExpired
        case .taskCancelled: .refusalTaskCancelled
        case .notHolder: .refusalNotHolder
        case .forbidden: .refusalForbidden
        case .invalidState: .refusalInvalidState
        case .pending: .refusalPending
        case .onHold: .refusalOnHold
        case .briefingNotAcknowledged: .refusalBriefingNotAcknowledged
        case .briefingChanged: .refusalBriefingChanged
        case .criteriaIncomplete: .refusalCriteriaIncomplete
        case .blockedByRule: .refusalBlockedByRule
        case .credentialInUse: .refusalCredentialInUse
        case .duplicateName: .refusalDuplicateName
        case .notEligible: .refusalNotEligible
        }
    }

    /// The sentence for a transport error's code.
    static func transport(_ code: TransportErrorCode) -> ShellCopy {
        switch code {
        case .malformed: .transportMalformed
        case .unauthenticated: .transportUnauthenticated
        case .notFound: .transportNotFound
        case .keyReused: .transportKeyReused
        case .invalid: .transportInvalid
        }
    }

    /// The sentence for anything a call threw: a refusal or a transport error
    /// by its code, a network failure as "can't reach", and the rest as the
    /// general line. The server's own wording is never shown.
    static func sentence(for error: any Error) -> ShellCopy {
        switch error {
        case LeverageClientError.refused(let refusal): Self.refusal(refusal.code)
        case let error as TransportError: transport(error.code)
        case is URLError: .cannotReach
        default: .somethingWentWrong
        }
    }
}
