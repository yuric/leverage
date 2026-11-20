import Foundation

/// The owner-facing sentences of the Needs you screen and of its
/// notifications (HM-24, HM-28, HM-29, HM-30). A sentence with a `{name}` in
/// it is filled in by `filled(_:)`. HM-24 names the words; "round" is one of
/// the ten banned words (L792), so the PRD's item name "Past the round limit"
/// reads "Sent back too many times" where it stands alone.
enum NeedsYouCopy: OwnerFacingCopy {
    case title, empty, loading

    // Account signed out.
    case signedOutHeading, signedOutBody, signInAgain, signInWaiting, signInWaitingGemini
    // Limit with no reset time.
    case limitHeading, limitBody
    // Sent back too many times.
    case sentBackHeading, sentBackBody, letItTryOnceMore, changeTask, cancelTask
    case cancelQuestion, cancelConfirm, cancelKeep
    // The five items of the rule checks.
    case refusedHeading, refusedBody, rerunHeading, rerunBody, couldNotRunHeading, couldNotRunBody
    case noReviewerHeading, noReviewerBody
    case offlineHeading, offlineBodyOne, offlineBodyMany, offlineBodyNone, offlineCause
    case ruleLabel, reasonLabel
    case letThroughOnce, runAgain, turnRuleOff, connectAgent
    case letThroughQuestion, letThroughPlaceholder, letThroughConfirm, turnOffQuestion, turnOffConfirm, goBack
    // An item this version cannot open.
    case unknownLine

    // Notifications.
    case notificationsOff, settledBeforeYouSaw
    case kindSignedOut, kindLimit, kindSentBack, kindOther
    // Names used when a read could not say.
    case aTask, anAccount

    var text: String {
        switch self {
        case .title: "Needs you"
        case .empty: "Nothing needs you right now."
        case .loading: "Looking for what needs you…"

        case .signedOutHeading: "{account} is signed out"
        case .signedOutBody:
            "{task} stopped because {account} is signed out and no other account can take over. Sign in again to continue."
        case .signInAgain: "Sign in again"
        case .signInWaiting: "Waiting for you to sign in in the window that opened"
        case .signInWaitingGemini: "Sign in to Antigravity on this Mac. leverage continues on its own."

        case .limitHeading: "{account} is at its limit"
        case .limitBody:
            "{task} is waiting. {provider} did not say when {account} is available again. When it is, choose Verify on {account} in Credentials and the task continues. If the agent's time on the task runs out first, the task goes back to waiting for any agent."

        case .sentBackHeading: "{task} was sent back {count} times"
        case .sentBackBody: "It is paused until you choose what happens next."
        case .letItTryOnceMore: "Let it try once more"
        case .changeTask: "Change the task"
        case .cancelTask: "Cancel task"
        case .cancelQuestion: "Cancel this task?"
        case .cancelConfirm: "Cancel task"
        case .cancelKeep: "Keep it"

        case .refusedHeading: "Every agent was turned away"
        case .refusedBody:
            "A rule turned away every agent that could build {task}. It waits until you choose what happens next."
        case .rerunHeading: "Checked too many times"
        case .rerunBody:
            "{task} was checked as many times as the rule allows without an answer. It waits until you choose what happens next."
        case .couldNotRunHeading: "A check could not run"
        case .couldNotRunBody:
            "A check on {task} could not run, so the task waits. Run it again, let it through, or turn the rule off."
        case .noReviewerHeading: "No agent may review this"
        case .noReviewerBody:
            "{task} is built and waits for a review, but no connected agent may review it. Connect an agent from another provider, or turn the rule off. It continues on its own when an agent may review it."
        case .offlineHeading: "The agent that checks tasks is offline"
        case .offlineBodyOne: "{count} check is waiting. It starts on its own when the agent is back."
        case .offlineBodyMany: "{count} checks are waiting. They start on their own when the agent is back."
        case .offlineBodyNone: "Checks wait until the agent is back, and then start on their own."
        case .offlineCause: "The cause is {account}. Look at it in Credentials."
        case .ruleLabel: "Rule"
        case .reasonLabel: "Reason"
        case .letThroughOnce: "Let it through once"
        case .runAgain: "Run it again"
        case .turnRuleOff: "Turn the rule off"
        case .connectAgent: "Connect an agent"
        case .letThroughQuestion: "Why are you letting it through?"
        case .letThroughPlaceholder: "Your reason"
        case .letThroughConfirm: "Let it through"
        case .turnOffQuestion: "Turn this rule off for every task?"
        case .turnOffConfirm: "Turn it off"
        case .goBack: "Go back"
        case .unknownLine: "{task} needs you, and leverage cannot open this kind of item yet."

        case .notificationsOff:
            "Notifications are off for leverage. Turn them on in System Settings to be told when something needs you."
        case .settledBeforeYouSaw: "This was settled before you saw it."
        case .kindSignedOut: "Account signed out"
        case .kindLimit: "Limit with no reset time"
        case .kindSentBack: "Sent back too many times"
        case .kindOther: "Something needs you"

        case .aTask: "A task"
        case .anAccount: "An account"
        }
    }
}
