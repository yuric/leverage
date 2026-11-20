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
    case pausedAtLimit, allowOneMoreTry, cancelTask
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
        }
    }
}
