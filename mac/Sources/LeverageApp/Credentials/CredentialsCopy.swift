import Foundation
import LeverageKit

/// The owner-facing sentences of the Credentials screen and of the Add
/// credential pop-up (MA-8, MA-17, MA-26, MA-27, PV-4, PV-5, CL-19). A
/// sentence with a `{name}` in it is filled in by `filled(_:)`. The words
/// come from the mockup where it draws them.
enum CredentialsCopy: OwnerFacingCopy {
    // The list.
    case loading, empty, header, addCredential
    case kindLogin, kindToken
    case statusSignedOut
    case usageReady, usageSignedOut
    case verify, verifying, verifyAll, refresh, readingUsage
    case noTokens, active, rowActions, rename, renaming, renameField, remove, removing
    case removeTitle, removeMessage, inUse, cleanupFailed
    case unavailable, noReader, untestedVersion, lookedSignedOut, tokenStopped, tokenUse, handoffModel
    case percentUsed, resetsAt, resetsAvailable, resetCount, resetExpiry, readAge
    case resetFiveHour, resetWeekly, resetPerModel, resetFull
    // At its limit, and Sign in again on a signed-out login (HM-45, HM-47).
    case usageLimitUntil, usageLimitNoTime, signInAgain

    // The pop-up's two steps.
    case sheetTitle, stepPick, stepName
    case nameLabel, namePlaceholder, nameHint, nameRequired
    case added, back, cancel, signIn, retry

    // The check list and what it waits for.
    case checkInstalled, checkSignedIn, checkAnswers
    case stateWaiting, stateWorking, statePassed, stateFailed
    case waitingSignIn, waitingGemini
    case installAsk, installCant, installButton, installing, installFailed

    // One line for a check that failed.
    case failNotInstalled, failNotSignedIn, failNoAnswer, failRejected, failUnreachable, failTimedOut, failedGeneric

    var text: String {
        switch self {
        case .loading: "Loading credentials…"
        case .empty: "No logins yet. Add one so an agent can run on it."
        case .header: "The order they take over in is set on Handoff."
        case .addCredential: "Add credential"
        case .kindLogin: "Subscription login"
        case .kindToken: "API token"
        case .statusSignedOut: "Signed out"
        case .usageReady: "Signed in and answering."
        case .usageSignedOut: "Not signed in."
        case .verify: "Verify"
        case .verifying: "Checking…"
        case .verifyAll: "Verify all"
        case .refresh: "Refresh"
        case .readingUsage: "Reading usage…"
        case .noTokens: "No API tokens yet."
        case .active: "Active"
        case .rowActions: "Actions for {name}"
        case .rename: "Rename"
        case .renaming: "Renaming…"
        case .renameField: "Name"
        case .remove: "Remove"
        case .removing: "Removing…"
        case .removeTitle: "Remove {name}?"
        case .removeMessage: "You can add this account again from Credentials."
        case .inUse: "{name} is in use by an agent or by work that is not finished."
        case .cleanupFailed: "The account was removed. Its saved sign-in or token may still be on this Mac."
        case .unavailable: "Unavailable right now."
        case .noReader: "Unavailable. Leverage does not read usage for {provider} yet."
        case .untestedVersion: "Unavailable. Leverage has not been checked with {tool} {version} yet."
        case .lookedSignedOut: "Looked signed out when last read. Choose Verify to check."
        case .tokenStopped: "This token no longer works. Remove it and add it again."
        case .tokenUse: "Not used for work yet. Leverage checks it and shows what its provider reports."
        case .handoffModel: "Uses {model} when work moves here from another provider"
        case .percentUsed: "{percent} used"
        case .resetsAt: "Resets {time}."
        case .resetsAvailable: "Available resets: {resets}"
        case .resetCount: "{count} {kind}"
        case .resetExpiry: "{reset}, expires {time}"
        case .readAge: "Last read {age}."
        case .resetFiveHour: "5-hour"
        case .resetWeekly: "weekly"
        case .resetPerModel: "per-model"
        case .resetFull: "full"
        case .usageLimitUntil: "At its limit until {time}."
        case .usageLimitNoTime: "At its limit. {provider} did not say when it is available again."
        case .signInAgain: "Sign in again"

        case .sheetTitle: "Add credential"
        case .stepPick: "Step 1 of 2. Which provider?"
        case .stepName: "Step 2 of 2. Name it and sign in."
        case .nameLabel: "Name for this {provider} login"
        case .namePlaceholder: "Personal"
        case .nameHint: "When you choose Sign in, we check that the {provider} tool is installed, signed in and answering."
        case .nameRequired: "Give it a name."
        case .added: "Added"
        case .back: "Back"
        case .cancel: "Cancel"
        case .signIn: "Sign in"
        case .retry: "Retry"

        case .checkInstalled: "{tool} is installed"
        case .checkSignedIn: "You are signed in to {tool}"
        case .checkAnswers: "{tool} answers a short test"
        case .stateWaiting: "Waiting"
        case .stateWorking: "In progress"
        case .statePassed: "Done"
        case .stateFailed: "Failed"
        case .waitingSignIn: "Waiting for you to sign in in the window that opened"
        case .waitingGemini: "Sign in to Antigravity on this Mac. Leverage continues on its own."
        case .installAsk: "{tool} is not installed. Leverage can install {what} from {source}."
        case .installCant: "Leverage can't install {tool} yet. Install it, and Leverage continues on its own."
        case .installButton: "Install"
        case .installing: "Installing {tool}…"
        case .installFailed: "The install did not finish. Try again."

        case .failNotInstalled: "{tool} is not installed."
        case .failNotSignedIn: "{tool} is not signed in."
        case .failNoAnswer: "{tool} did not answer the short test."
        case .failRejected: "{tool} turned the short test down."
        case .failUnreachable: "{tool} could not be reached. Check this Mac's internet connection."
        case .failTimedOut: "{tool} took too long."
        case .failedGeneric: "Something stopped the checks. Try again."
        }
    }
}
