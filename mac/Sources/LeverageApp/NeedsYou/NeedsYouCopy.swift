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
    case limitHeading, limitBody, limitBodyAutomatic
    // Sent back too many times.
    case sentBackHeading, sentBackBody, letItTryOnceMore, changeTask, cancelTask
    case cancelQuestion, cancelConfirm, cancelKeep
    // The five items of the rule checks.
    case refusedHeading, refusedBody, rerunHeading, rerunBody, couldNotRunHeading, couldNotRunBody
    case noReviewerHeading, noReviewerBody
    case offlineHeading, offlineBodyOne, offlineBodyMany, offlineBodyNone, offlineBodyNotSetUp, offlineCause,
        offlineCauseSignedOut, offlineCauseLimitUntil
    case ruleLabel, reasonLabel
    case letThroughOnce, runAgain, turnRuleOff, connectAgent
    case letThroughQuestion, letThroughPlaceholder, letThroughConfirm, turnOffQuestion, turnOffConfirm, goBack
    case questionHeading, questionAssuming, questionWaiting, questionAssumption, keepAssumption, answerDifferently
    case answerTitle, sendAnswer, closeSheet
    case approvalHeading, approvalBody, approve, stop
    case publish, pay, send, delete, publishing, paying, sending, deleting
    case stoppedHeading, stoppedBody, ruleStoppedAction, ownerStoppedAction, agentStoppedAction
    case startedWarning, waive, returnForRework, criteriaToReopen
    case unconfirmedHeading, unconfirmedBody, unconfirmedBeforeStart, unconfirmedAfterStart, unconfirmedStartUnknown
    case offerAgain, markDone, actionChoice, approvedByYou, anAgent, approvalUnknown
    case accessHeading, accessBody, grantAccess
    case taskBudgetHeading, projectBudgetHeading, aProject, reportedAmount
    case raiseCap, changeBudget, resumeProject, amount, amountHint, saveAmount

    case agentTaskIncompleteHeading, agentTaskIncompleteBody, agentTasksAtLimitHeading, agentTasksAtLimitBody
    case completeContract, draftContract

    // An item whose details could not be read.
    case detailsUnavailable

    // Notifications.
    case notificationsOff, openSystemSettings, settledBeforeYouSaw
    case kindSignedOut, kindLimit, kindSentBack, kindOther
    case kindQuestion, kindApproval, kindStopped, kindUnconfirmed, kindAccess, kindBudget
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
        case .signInWaitingGemini: "Sign in to Antigravity on this Mac. Leverage continues on its own."

        case .limitHeading: "{account} is at its limit"
        case .limitBody:
            "{task} is waiting. {provider} did not say when {account} is available again. When it is, choose Verify on {account} in Credentials and the task continues."
        case .limitBodyAutomatic:
            "{task} is waiting. {provider} did not say when {account} is available again. Leverage looks every 10 minutes and continues by itself when it is. You can also choose Verify on {account} in Credentials."

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
            "{task} was checked as many times as the rule allows, and it did not pass. It waits until you choose what happens next."
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
        case .offlineBodyNotSetUp: "No agent is set up to check tasks. Connect one in Agents."
        case .offlineCause: "The cause is {account}. Look at it in Credentials."
        case .offlineCauseSignedOut: "{account} is signed out. Look at it in Credentials."
        case .offlineCauseLimitUntil: "{account} is at its limit until {time}. Look at it in Credentials."
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
        case .questionHeading: "{agent} asked while working on {task}"
        case .questionAssuming: "It is assuming {assumption} and has kept working."
        case .questionWaiting: "It is waiting for your answer."
        case .questionAssumption: "It is assuming {assumption}."
        case .keepAssumption: "Keep that"
        case .answerDifferently: "Answer differently"
        case .answerTitle: "Your answer"
        case .sendAnswer: "Send answer"
        case .closeSheet: "Cancel"
        case .approvalHeading: "{action}?"
        case .approvalBody: "{task} passed its review. {action} cannot be undone."
        case .approve: "Approve"
        case .stop: "Do not {verb}"
        case .publish: "Publish"
        case .pay: "Pay"
        case .send: "Send"
        case .delete: "Delete"
        case .publishing: "Publishing"
        case .paying: "Paying"
        case .sending: "Sending"
        case .deleting: "Deleting"
        case .stoppedHeading: "{verb} was stopped"
        case .stoppedBody: "The task is waiting for you to choose what happens next."
        case .ruleStoppedAction: "A rule stopped this action."
        case .ownerStoppedAction: "You stopped this action."
        case .agentStoppedAction: "{agent} stopped this action."
        case .startedWarning: "Something may already have gone out."
        case .waive: "Skip it"
        case .returnForRework: "Send the task back"
        case .criteriaToReopen: "Choose the parts of the work the agent should do again."
        case .unconfirmedHeading: "Did {action} happen?"
        case .unconfirmedBody: "{agent} was to {action}, approved by {who}, and stopped responding {when}."
        case .unconfirmedBeforeStart: "before it said it had started"
        case .unconfirmedAfterStart: "after it said it had started"
        case .unconfirmedStartUnknown: "before its progress could be confirmed"
        case .offerAgain: "Ask {agent} again"
        case .markDone: "It was done"
        case .actionChoice: "{choice} ({description})"
        case .approvedByYou: "you"
        case .anAgent: "An agent"
        case .approvalUnknown: "an agent"
        case .accessHeading: "{agent} needs access"
        case .accessBody: "Give the agent the access it needs to continue."
        case .grantAccess: "I have given access"
        case .taskBudgetHeading: "{task} reached its spending limit"
        case .projectBudgetHeading: "{project} reached its budget"
        case .aProject: "A project"
        case .reportedAmount: "{amount} reported"
        case .raiseCap: "Raise the limit"
        case .changeBudget: "Change the budget"
        case .resumeProject: "Continue anyway"
        case .amount: "Amount in US dollars"
        case .amountHint: "Use up to two decimal places. Leave it empty for no limit."
        case .saveAmount: "Save"
        case .agentTaskIncompleteHeading: "A task an agent added needs its contract"
        case .agentTaskIncompleteBody: "“{task}” is waiting in the Backlog."
        case .agentTasksAtLimitHeading: "Agents have added 50 open tasks"
        case .agentTasksAtLimitBody: "When one of those tasks is done or cancelled, agents can add another."
        case .completeContract: "Complete the contract"
        case .draftContract: "Ask a planner to draft it"

        case .detailsUnavailable: "The details could not be read."

        case .notificationsOff:
            "Notifications are off for Leverage. Turn them on in System Settings to be told when something needs you."
        case .openSystemSettings: "Open System Settings"
        case .settledBeforeYouSaw: "This was settled before you saw it."
        case .kindSignedOut: "Account signed out"
        case .kindLimit: "Limit with no reset time"
        case .kindSentBack: "Sent back too many times"
        case .kindOther: "Something needs you"
        case .kindQuestion: "A question needs your answer"
        case .kindApproval: "An action needs your approval"
        case .kindStopped: "An action was stopped"
        case .kindUnconfirmed: "An action could not be confirmed"
        case .kindAccess: "An agent needs access"
        case .kindBudget: "A spending limit was reached"

        case .aTask: "A task"
        case .anAccount: "An account"
        }
    }
}
