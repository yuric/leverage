import LeverageKit

/// The owner-facing sentences of the task page and its log (MA-28, MA-29). A
/// sentence with a `{name}` in it is filled in by `filled(_:)`.
///
/// MA-29 names the second button "Allow one more round", but "round" is one of
/// the ten words the plain-language rule bans (L792), so it reads "Allow one
/// more try".
enum TaskPageCopy: OwnerFacingCopy {
    case loading, noTask

    // The sections.
    case sectionGoal, sectionDetails, sectionCriteria, sectionWork, sectionLog
    case workNotGiven, emptyLog, noEvidence

    // A criterion and its evidence.
    case criterionOpen, criterionStarted, criterionPassed
    case evidenceLink, evidenceNote

    // What the owner can do.
    case sendToAgents, sending, backlogHint
    case pausedAtLimit, allowOneMoreTry, cancelTask, moveToBacklog, pauseTask, continueTask, changeTask
    case cancelQuestion, cancelExplanation, keepTask, working

    // The log's sentences.
    case anAgent, aPartOfTheTask
    case logCreated, logContractChanged, logReady, logClaimed, logBriefingRead
    case logCriterionStarted, logCriterionPassed, logCriterionReopened
    case logEvidenceLink, logEvidenceNote, logSubmitted
    case logReviewStarted, logReviewReleased, logReviewLeaseExpired, logReviewPassed
    case logReviewFailed, logReviewFailedList, logReturnedForRework, logDone, logCancelled
    case logReleasedUnable, logReleasedNotSuited, logReleasedStopping, logReleasedSwitchedOff
    case logReleasedRemoved, logReleasedOther, logLeaseExpired
    case logPausedAtLimit, logPaused, logNoLongerPaused, logUpdated

    // The log's sentences for an interruption, a handoff, a wait and a continuation (HM-43).
    case logLimitReached, logLimitReachedIn, logLimitReachedModel, logLimitResets
    case logSignedOutStopped, logSignedOutFound, logVerified, logSwitched, logSwitchedFrom
    case logWaitingForAccount, logWaitingForSignIn, logOwnerPaused, logAgentPaused
    case logAccountAvailable, logAccountSignedInAgain, logOwnerContinued, logAgentResumed, logWaitsForAccount
    case logPromoted, logReturned, logReturnedNoAgent
    case logInboxSignedOut, logInboxLimit, logInboxPastLimit, logInboxOther, logInboxSettled
    case logChoseTryAgain, logChoseChange, logChoseSignIn
    case logSeatPaused, logSeatResumed, logSeatChanged
    case logReviewStoppedLimit, logReviewStoppedSignedOut
    case backAtWork, backAtWorkAtOnce, notBackAtWork, endedBeforeBackAtWork

    // The Timing section (RD-28) and the plain name of each step (RM-1).
    case sectionTiming, timingTotal, timingBeforeIdeas, timingSoFar
    case stepIdea, stepDraft, stepWaitContract, stepCheck, stepWaitReady, stepBriefing, stepBuild, stepFinish
    case stepWaitReview, stepReview, stepWaitBuilder, stepRework, stepWaitOwner, stepWaitSeat, stepWaitLimit

    // The checklist (RD-28, RD-49): a line for each check, and what the owner can do with it.
    case sectionChecks, checkPassed, checkFailed, checkNotApplicable, checkApplied, checkError, checkWithdrawn
    case checkBeingChecked, checkTooManyTimes, aCheck
    case wordingOf, checkerApp, checkerModel, onFailBlock, onFailWarn
    case youLetItThrough, youLetItThroughWhy
    case letThroughOnce, runItAgain

    // The sheet that asks why a check is let through once (RD-29, RD-48).
    case letThroughTitle, letThroughExplain, letThroughReasonLabel, letThroughReasonPlaceholder
    case letThroughConfirm, letThroughSending, letThroughCancel

    // What the page says while a check runs, and about a draft of the details (RD-27, RD-37).
    case beingChecked, beingCheckedBy
    case draftDetails, draftQueued, draftWriting, draftNotWritten

    // The log's sentences for the rule checks, the work behind them and the new waits (milestone 4).
    case logCheckQueued, logCheckStarted, logCheckPassed, logCheckFailed, logCheckNotApplicable, logCheckApplied
    case logCheckAppliedRefused, logCheckAppliedEscalated, logCheckAppliedSameBuilder, logCheckError
    case logCheckWithdrawn, logCheckOther
    case logJobQueuedCheck, logJobQueuedDraft, logJobQueuedOther
    case logJobClaimedCheck, logJobClaimedDraft, logJobClaimedOther
    case logJobFinishedCheck, logJobFinishedDraft, logJobFinishedOther
    case logJobTimedOut, logJobRequeued, logJobWithdrawn
    case logHoldContractIncomplete, logHoldCheckError, logHoldRerunLimit, logHoldClaimGateFailed
    case logInboxEveryAgentTurnedAway, logInboxCheckedTooManyTimes, logInboxCheckCouldNotRun
    case logInboxNoReviewer, logInboxOrchestratorOffline
    case logChoseLetThrough, logChoseRunAgain, logChoseTurnRuleOff

    var text: String {
        switch self {
        case .loading: "Loading the task…"
        case .noTask: "That is no longer there."

        case .sectionGoal: "The goal"
        case .sectionDetails: "Details"
        case .sectionCriteria: "How you will know it is done"
        case .sectionWork: "Where the work is"
        case .sectionLog: "What happened"
        case .workNotGiven: "Not given yet"
        case .emptyLog: "Nothing has happened yet."
        case .noEvidence: "No evidence yet"

        case .criterionOpen: "Not started"
        case .criterionStarted: "In progress"
        case .criterionPassed: "Done"
        case .evidenceLink: "Link"
        case .evidenceNote: "Note"

        case .sendToAgents: "Send to agents"
        case .sending: "Sending…"
        case .backlogHint: "This task is waiting in Backlog. Check what done looks like, then send it to agents."
        case .pausedAtLimit: "Sent back too many times. Paused."
        case .allowOneMoreTry: "Allow one more try"
        case .cancelTask: "Cancel task"
        case .cancelQuestion: "Cancel this task?"
        case .cancelExplanation: "Any agent working on it stops. This can't be undone."
        case .keepTask: "Keep task"
        case .working: "One moment…"

        case .anAgent: "An agent"
        case .aPartOfTheTask: "a part of the task"
        case .logCreated: "You added the task."
        case .logContractChanged: "The details were saved."
        case .logReady: "The task is ready for an agent to pick up."
        case .logClaimed: "{agent} took the task."
        case .logBriefingRead: "{agent} read the briefing."
        case .logCriterionStarted: "{agent} started on {criterion}."
        case .logCriterionPassed: "{agent} finished {criterion}."
        case .logCriterionReopened: "{criterion} needs more work."
        case .logEvidenceLink: "{agent} added a link to {criterion}."
        case .logEvidenceNote: "{agent} added a note to {criterion}."
        case .logSubmitted: "{agent} handed in the work for review."
        case .logReviewStarted: "{agent} started reviewing the work."
        case .logReviewReleased: "{agent} stepped away from the review. Another reviewer will take it."
        case .logReviewLeaseExpired: "The reviewer stopped responding, so the review went back to waiting."
        case .logReviewPassed: "{agent} approved the work."
        case .logReviewFailed: "{agent} sent the work back."
        case .logReviewFailedList: "{agent} sent the work back. Not done yet: {list}."
        case .logReturnedForRework: "The work went back to the builder to fix."
        case .logDone: "The work passed review. The task is done."
        case .logCancelled: "You cancelled the task."
        case .logReleasedUnable: "{agent} could not carry on, so the task went back to waiting."
        case .logReleasedNotSuited: "{agent} said the task does not suit it, so the task went back to waiting."
        case .logReleasedStopping: "{agent} was stopped, so the task went back to waiting."
        case .logReleasedSwitchedOff: "{agent} was switched off, so the task went back to waiting."
        case .logReleasedRemoved: "{agent} was removed, so the task went back to waiting."
        case .logReleasedOther: "{agent} stopped working on the task, so it went back to waiting."
        case .logLeaseExpired: "The agent stopped responding, so the task went back to waiting."
        case .logPausedAtLimit: "Sent back too many times. Paused."
        case .logPaused: "The task was paused."
        case .logNoLongerPaused: "The task is no longer paused."
        case .logUpdated: "The task was updated."
        case .moveToBacklog: "Move to Backlog"
        case .pauseTask: "Pause this task"
        case .continueTask: "Continue this task"
        case .changeTask: "Change the task"

        case .logLimitReached: "{account} reached its limit."
        case .logLimitReachedIn: "{account} reached its {window} limit."
        case .logLimitReachedModel: "{account} reached its limit for one model."
        case .logLimitResets: "It resets at {time}."
        case .logSignedOutStopped: "{account} was signed out, so {agent} stopped."
        case .logSignedOutFound: "{account} was found signed out when it was checked."
        case .logVerified: "{account} was signed in again."
        case .logSwitched: "{agent} went on with {account} from the saved work."
        case .logSwitchedFrom: "{agent} moved from {from} to {account} and went on from the saved work."
        case .logWaitingForAccount: "The task is waiting for {account} to be available again."
        case .logWaitingForSignIn: "The task is paused until {account} is signed in again."
        case .logOwnerPaused: "You paused the task."
        case .logAgentPaused: "The agent working on the task was paused, so it is waiting."
        case .logAccountAvailable: "{account} is available again, so the task goes on."
        case .logAccountSignedInAgain: "{account} is signed in again, so the task goes on."
        case .logOwnerContinued: "You continued the task."
        case .logAgentResumed: "The agent was resumed, so the task goes on."
        case .logWaitsForAccount: "It is waiting for an account to be available."
        case .logPromoted: "You moved the idea to Backlog."
        case .logReturned: "The agent stopped and the task went back to Backlog."
        case .logReturnedNoAgent: "The task went back to Backlog."
        case .logInboxSignedOut: "An account is signed out. This needs you: sign in again."
        case .logInboxLimit: "An account is at its limit and did not say when it is available again. This needs you."
        case .logInboxPastLimit: "The task was sent back too many times. This needs you."
        case .logInboxOther: "This needs you."
        case .logInboxSettled: "That no longer needs you."
        case .logChoseTryAgain: "You let it try once more."
        case .logChoseChange: "You changed the task."
        case .logChoseSignIn: "You signed in again."
        case .logSeatPaused: "{agent} was paused."
        case .logSeatResumed: "{agent} was resumed."
        case .logSeatChanged: "{agent} was changed."
        case .logReviewStoppedLimit:
            "The review stopped because {account} reached its limit. It waits for a reviewer with an available account."
        case .logReviewStoppedSignedOut:
            "The review stopped because {account} was signed out. It waits for a reviewer with an available account."
        case .backAtWork: "Back at work after {duration}."
        case .backAtWorkAtOnce: "Back at work at once."
        case .notBackAtWork: "Not back at work yet."
        case .endedBeforeBackAtWork: "The task ended before the work started again."

        case .sectionTiming: "Timing"
        case .timingTotal: "Total"
        case .timingBeforeIdeas: "Before it left Ideas"
        case .timingSoFar: "so far"
        case .stepIdea: "Idea"
        case .stepDraft: "Writing the details"
        case .stepWaitContract: "Waiting for details"
        case .stepCheck: "Being checked"
        case .stepWaitReady: "Waiting for an agent"
        case .stepBriefing: "Reading the task"
        case .stepBuild: "Building"
        case .stepFinish: "Wrapping up"
        case .stepWaitReview: "Waiting for a reviewer"
        case .stepReview: "Reviewing"
        case .stepWaitBuilder: "Waiting for its agent"
        case .stepRework: "Fixing after review"
        case .stepWaitOwner: "Waiting for you"
        case .stepWaitSeat: "Agent paused"
        case .stepWaitLimit: "Waiting for an account"

        case .sectionChecks: "Checks"
        case .checkPassed: "Passed"
        case .checkFailed: "Did not pass"
        case .checkNotApplicable: "Did not apply"
        case .checkApplied: "Applied"
        case .checkError: "Could not run"
        case .checkWithdrawn: "Not needed any more"
        case .checkBeingChecked: "Being checked"
        case .checkTooManyTimes: "Checked too many times"
        case .aCheck: "A check"
        case .wordingOf: "wording of {date}"
        case .checkerApp: "leverage checks this itself"
        case .checkerModel: "An agent checks this"
        case .onFailBlock: "Stop the task"
        case .onFailWarn: "Only note it"
        case .youLetItThrough: "You let it through"
        case .youLetItThroughWhy: "You let it through: {reason}"
        case .letThroughOnce: "Let it through once"
        case .runItAgain: "Run it again"

        case .letThroughTitle: "Let “{rule}” through once?"
        case .letThroughExplain:
            "The check is set aside this one time and the task goes on. Say why, so the log shows it."
        case .letThroughReasonLabel: "Why are you letting it through?"
        case .letThroughReasonPlaceholder: "The details are in the ticket"
        case .letThroughConfirm: "Let it through once"
        case .letThroughSending: "Sending…"
        case .letThroughCancel: "Cancel"

        case .beingChecked: "Being checked"
        case .beingCheckedBy: "Being checked: {rules}"
        case .draftDetails: "Draft the details"
        case .draftQueued: "Waiting for an agent to write the details."
        case .draftWriting: "An agent is writing the details."
        case .draftNotWritten: "The details could not be written. Try again, or write them yourself."

        case .logCheckQueued: "“{rule}” is waiting to be checked."
        case .logCheckStarted: "“{rule}” is being checked."
        case .logCheckPassed: "“{rule}” passed."
        case .logCheckFailed: "“{rule}” did not pass."
        case .logCheckNotApplicable: "“{rule}” did not apply."
        case .logCheckApplied: "“{rule}” was applied."
        case .logCheckAppliedRefused: "“{rule}” turned a reviewer away."
        case .logCheckAppliedEscalated: "“{rule}” moved the task to a stronger model."
        case .logCheckAppliedSameBuilder: "“{rule}” left the fix with the same agent."
        case .logCheckError: "“{rule}” could not run."
        case .logCheckWithdrawn: "“{rule}” is not needed any more."
        case .logCheckOther: "“{rule}” was checked."
        case .logJobQueuedCheck: "The check is waiting for an agent that checks tasks."
        case .logJobQueuedDraft: "The details are waiting for an agent to write them."
        case .logJobQueuedOther: "Something is waiting for an agent."
        case .logJobClaimedCheck: "{agent} started on the check."
        case .logJobClaimedDraft: "{agent} started writing the details."
        case .logJobClaimedOther: "{agent} took it up."
        case .logJobFinishedCheck: "{agent} finished the check."
        case .logJobFinishedDraft: "{agent} wrote the details."
        case .logJobFinishedOther: "{agent} finished it."
        case .logJobTimedOut: "The agent did not answer in time."
        case .logJobRequeued: "It was put back to wait for another agent."
        case .logJobWithdrawn: "It is not needed any more."
        case .logHoldContractIncomplete: "The task needs details before it can be sent to agents."
        case .logHoldCheckError: "A check could not run, so the task waits for you."
        case .logHoldRerunLimit: "A check ran on the same work too many times, so the task waits for you."
        case .logHoldClaimGateFailed: "Every agent that tried to take the task was turned away, so it waits for you."
        case .logInboxEveryAgentTurnedAway: "Every agent was turned away. This needs you."
        case .logInboxCheckedTooManyTimes: "Checked too many times. This needs you."
        case .logInboxCheckCouldNotRun: "A check could not run. This needs you."
        case .logInboxNoReviewer: "No agent may review this. This needs you."
        case .logInboxOrchestratorOffline: "The agent that checks tasks is offline."
        case .logChoseLetThrough: "You let it through once."
        case .logChoseRunAgain: "You ran the check again."
        case .logChoseTurnRuleOff: "You turned the rule off."
        }
    }

    /// The plain name of a step (RM-1).
    static func stepName(_ kind: StepKind) -> TaskPageCopy {
        switch kind {
        case .idea: .stepIdea
        case .draft: .stepDraft
        case .waitContract: .stepWaitContract
        case .check: .stepCheck
        case .waitReady: .stepWaitReady
        case .briefing: .stepBriefing
        case .build: .stepBuild
        case .finish: .stepFinish
        case .waitReview: .stepWaitReview
        case .review: .stepReview
        case .waitBuilder: .stepWaitBuilder
        case .rework: .stepRework
        case .waitOwner: .stepWaitOwner
        case .waitSeat: .stepWaitSeat
        case .waitLimit: .stepWaitLimit
        }
    }
}
