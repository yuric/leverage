import Foundation
import LeverageKit

/// One line of a task's log: a plain sentence, with the time it happened.
struct LogEntry: Identifiable, Equatable, Sendable {
    let id: UUID
    let seq: Int
    let at: Date
    let text: String
}

/// The task page's log: each event of the task as one plain sentence, in the
/// order of the log (L799, MA-28). Names come from the read's `names`, and a
/// criterion's words from the page's criteria. An event this milestone has no
/// sentence for reads as a general one rather than leaving a gap.
enum TaskLog {
    static func entries(
        events: [EventRecord], names: [LogName], criteria: [Criterion], recoveryTimes: [RecoveryTime] = [],
        accounts: [UUID: String] = [:], ruleChecks: [RuleCheckRow] = [], clock: ResetClock = .system
    ) -> [LogEntry] {
        let seats = Dictionary(
            names.filter { $0.kind == .seat }.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        var credentials = Dictionary(
            names.filter { $0.kind == .credential }.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        credentials.merge(accounts) { _, read in read }
        let words = Dictionary(criteria.map { ($0.id, $0.text) }, uniquingKeysWith: { first, _ in first })
        let ordered = events.sorted { $0.seq < $1.seq }
        let context = Context(
            seats: seats, credentials: credentials, criteria: words,
            events: Dictionary(events.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
            recoveryTimes: recoveryTimes, clock: clock, returnedWhileHeld: returnedWhileHeld(ordered))
        return ordered.map { event in
            LogEntry(id: event.id, seq: event.seq, at: event.at, text: sentence(for: event, in: context))
        }
    }

    /// The `task.returned` events written while an agent held the task: a
    /// builder from its claim (or a fresh lease) until it let the task go,
    /// submitted it or lost it; a reviewer from the review's start until its
    /// verdict or its release. Only these stopped an agent: Ready has no
    /// holder, nor does a review no reviewer has taken.
    private static func returnedWhileHeld(_ ordered: [EventRecord]) -> Set<UUID> {
        var builder = false
        var reviewer = false
        var held: Set<UUID> = []
        for event in ordered {
            switch event.type {
            case .taskClaimed: builder = true
            case .taskSubmitted, .taskReleased, .taskLeaseExpired, .taskDone, .taskCancelled: builder = false
            case .reviewStarted: reviewer = true
            case .reviewReleased, .reviewLeaseExpired, .reviewPassed, .reviewFailed: reviewer = false
            case .taskReturned:
                if builder || reviewer { held.insert(event.id) }
                builder = false
                reviewer = false
            default: break
            }
            if case .string = event.payload["lease_seat_id"] { builder = true }
        }
        return held
    }

    private struct Context {
        let seats: [UUID: String]
        let credentials: [UUID: String]
        let criteria: [UUID: String]
        let events: [UUID: EventRecord]
        let recoveryTimes: [RecoveryTime]
        let clock: ResetClock
        let returnedWhileHeld: Set<UUID>

        func agent(_ event: EventRecord) -> String {
            guard event.actorKind == .seat, let id = event.actorID, let name = seats[id] else {
                return TaskPageCopy.anAgent.text
            }
            return name
        }

        /// The agent a payload or a subject names, or "An agent".
        func agent(named id: UUID?) -> String {
            id.flatMap { seats[$0] } ?? TaskPageCopy.anAgent.text
        }

        /// The account with this id as the owner knows it, or "an account".
        func account(_ id: UUID?) -> String {
            id.flatMap { credentials[$0] } ?? BoardCopy.anAccount.text
        }

        func uuid(_ event: EventRecord, _ key: String) -> UUID? {
            event.payload[key]?.stringValue.flatMap(UUID.init(uuidString:))
        }

        func credentialID(_ event: EventRecord) -> UUID? {
            event.subjectKind == .credential ? event.subjectID : uuid(event, "credential_id")
        }

        func criterionID(_ event: EventRecord) -> UUID? {
            if event.subjectKind == .criterion { return event.subjectID }
            return event.payload["criterion_id"]?.stringValue.flatMap(UUID.init(uuidString:))
        }

        /// The criterion's words in quotes, or "a part of the task".
        func criterion(_ event: EventRecord) -> String {
            guard let id = criterionID(event), let text = criteria[id] else { return TaskPageCopy.aPartOfTheTask.text }
            return "“\(text)”"
        }

        func failedCriteria(_ event: EventRecord) -> [String] {
            (event.payload["failed_criterion_ids"]?.arrayValue ?? [])
                .compactMap { $0.stringValue.flatMap(UUID.init(uuidString:)) }
                .compactMap { criteria[$0] }
                .map { "“\($0)”" }
        }

        /// The recovery time that starts at this interruption: the same kind,
        /// account and review, and the same moment.
        func recovery(for event: EventRecord) -> RecoveryTime? {
            let kind: RecoveryKind = event.type == .credentialLimitReached ? .limit : .signedOut
            let review = uuid(event, "review_id")
            return recoveryTimes.first {
                $0.kind == kind && $0.credentialID == credentialID(event) && $0.reviewID == review
                    && abs($0.startedAt.timeIntervalSince(event.effectiveAt)) < 1
            }
        }
    }

    /// The event's sentence, with what the task waits for after it (a wait
    /// cause the event carries) and how long the work was stopped (an
    /// interruption that ended).
    private static func sentence(for event: EventRecord, in context: Context) -> String {
        var text = baseSentence(for: event, in: context)
        if event.payload["wait_cause"]?.stringValue == "credential_limit" {
            text += " " + TaskPageCopy.logWaitsForAccount.text
        }
        if event.type == .credentialLimitReached || event.type == .credentialSignedOut,
            let recovery = context.recovery(for: event)
        {
            text += " " + recoveryWords(recovery)
        }
        return text
    }

    private static func recoveryWords(_ recovery: RecoveryTime) -> String {
        switch recovery.endedBy {
        case .handoff: return TaskPageCopy.backAtWorkAtOnce.text
        case .seatEvent:
            guard let seconds = recovery.seconds else { return TaskPageCopy.backAtWork.filled(["duration": "a while"]) }
            if seconds == 0 { return TaskPageCopy.backAtWorkAtOnce.text }
            return TaskPageCopy.backAtWork.filled(["duration": DurationWords.text(seconds: seconds)])
        case .notRecovered: return TaskPageCopy.endedBeforeBackAtWork.text
        case nil: return TaskPageCopy.notBackAtWork.text
        }
    }

    private static func resetTime(_ event: EventRecord, _ context: Context) -> String? {
        guard let text = event.payload["reset_at"]?.stringValue, let date = parse(text) else { return nil }
        return ResetTime.text(for: date, clock: context.clock)
    }

    private static func parse(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return plain.date(from: text) ?? fractional.date(from: text)
    }

    private static func limitSentence(_ event: EventRecord, _ context: Context) -> String {
        let account = capitalised(context.account(context.credentialID(event)))
        var text: String
        switch event.payload["window"]?.stringValue.flatMap(LimitWindow.init(rawValue:)) {
        case .fiveHour: text = TaskPageCopy.logLimitReachedIn.filled(["account": account, "window": "five-hour"])
        case .weekly: text = TaskPageCopy.logLimitReachedIn.filled(["account": account, "window": "weekly"])
        case .spend: text = TaskPageCopy.logLimitReachedIn.filled(["account": account, "window": "spending"])
        case .perModel: text = TaskPageCopy.logLimitReachedModel.filled(["account": account])
        case nil: text = TaskPageCopy.logLimitReached.filled(["account": account])
        }
        if let time = resetTime(event, context) { text += " " + TaskPageCopy.logLimitResets.filled(["time": time]) }
        return text
    }

    private static func holdOpenedSentence(_ event: EventRecord, _ context: Context) -> String {
        let account = context.account(context.uuid(event, "credential_id"))
        switch event.payload["reason"]?.stringValue.flatMap(HoldReason.init(rawValue:)) {
        case .roundsExceeded: return TaskPageCopy.logPausedAtLimit.text
        case .credentialLimit: return TaskPageCopy.logWaitingForAccount.filled(["account": account])
        case .credentialSignedOut: return TaskPageCopy.logWaitingForSignIn.filled(["account": account])
        case .ownerHold: return TaskPageCopy.logOwnerPaused.text
        case .seatPaused: return TaskPageCopy.logAgentPaused.text
        default: return TaskPageCopy.logPaused.text
        }
    }

    private static func holdClosedSentence(_ event: EventRecord, _ context: Context) -> String {
        let account = capitalised(context.account(context.uuid(event, "credential_id")))
        switch event.payload["reason"]?.stringValue.flatMap(HoldReason.init(rawValue:)) {
        case .credentialLimit: return TaskPageCopy.logAccountAvailable.filled(["account": account])
        case .credentialSignedOut: return TaskPageCopy.logAccountSignedInAgain.filled(["account": account])
        case .ownerHold: return TaskPageCopy.logOwnerContinued.text
        case .seatPaused: return TaskPageCopy.logAgentResumed.text
        default: return TaskPageCopy.logNoLongerPaused.text
        }
    }

    private static func inboxOpenedSentence(_ event: EventRecord) -> String {
        switch event.payload["kind"]?.stringValue.flatMap(NeedsYouItem.init(rawValue:)) {
        case .accountSignedOut: return TaskPageCopy.logInboxSignedOut.text
        case .limitWithNoResetTime: return TaskPageCopy.logInboxLimit.text
        case .pastRoundLimit: return TaskPageCopy.logInboxPastLimit.text
        default: return TaskPageCopy.logInboxOther.text
        }
    }

    private static func inboxResolvedSentence(_ event: EventRecord) -> String {
        switch event.payload["choice"]?.stringValue.flatMap(InboxChoice.init(rawValue:)) {
        case .allowAnotherRound: return TaskPageCopy.logChoseTryAgain.text
        case .editContract: return TaskPageCopy.logChoseChange.text
        case .cancel: return TaskPageCopy.logCancelled.text
        case .signInAgain: return TaskPageCopy.logChoseSignIn.text
        default: return TaskPageCopy.logInboxSettled.text
        }
    }

    private static func reviewReleasedSentence(_ event: EventRecord, _ context: Context, agent: [String: String]) -> String {
        guard let cause = event.causeID.flatMap({ context.events[$0] }) else {
            return TaskPageCopy.logReviewReleased.filled(agent)
        }
        let account = context.account(context.credentialID(cause))
        switch cause.type {
        case .credentialLimitReached: return TaskPageCopy.logReviewStoppedLimit.filled(["account": account])
        case .credentialSignedOut: return TaskPageCopy.logReviewStoppedSignedOut.filled(["account": account])
        default: return TaskPageCopy.logReviewReleased.filled(agent)
        }
    }

    private static func baseSentence(for event: EventRecord, in context: Context) -> String {
        let agent = ["agent": context.agent(event)]
        switch event.type {
        case .taskCreated: return TaskPageCopy.logCreated.text
        case .taskContractChanged: return TaskPageCopy.logContractChanged.text
        case .taskReady: return TaskPageCopy.logReady.text
        case .taskClaimed: return TaskPageCopy.logClaimed.filled(agent)
        case .taskBriefingAcknowledged: return TaskPageCopy.logBriefingRead.filled(agent)
        case .criterionStarted:
            return TaskPageCopy.logCriterionStarted.filled(agent.merging(["criterion": context.criterion(event)]) { $1 })
        case .criterionPassed:
            return TaskPageCopy.logCriterionPassed.filled(agent.merging(["criterion": context.criterion(event)]) { $1 })
        case .criterionReopened:
            return capitalised(TaskPageCopy.logCriterionReopened.filled(["criterion": context.criterion(event)]))
        case .evidenceAttached:
            let copy: TaskPageCopy = event.payload["kind"]?.stringValue == EvidenceKind.note.rawValue
                ? .logEvidenceNote : .logEvidenceLink
            return copy.filled(agent.merging(["criterion": context.criterion(event)]) { $1 })
        case .taskSubmitted: return TaskPageCopy.logSubmitted.filled(agent)
        case .reviewStarted: return TaskPageCopy.logReviewStarted.filled(agent)
        case .reviewReleased: return reviewReleasedSentence(event, context, agent: agent)
        case .reviewLeaseExpired: return TaskPageCopy.logReviewLeaseExpired.text
        case .reviewPassed: return TaskPageCopy.logReviewPassed.filled(agent)
        case .reviewFailed:
            let failed = context.failedCriteria(event)
            if failed.isEmpty { return TaskPageCopy.logReviewFailed.filled(agent) }
            return TaskPageCopy.logReviewFailedList.filled(agent.merging(["list": failed.joined(separator: ", ")]) { $1 })
        case .taskReturnedForRework: return TaskPageCopy.logReturnedForRework.text
        case .taskDone: return TaskPageCopy.logDone.text
        case .taskCancelled: return TaskPageCopy.logCancelled.text
        case .taskReleased:
            let reason = event.payload["reason"]?.stringValue.flatMap(ReleaseReason.init(rawValue:))
            let copy: TaskPageCopy
            switch reason {
            case .unableToContinue: copy = .logReleasedUnable
            case .notSuitedToThisSeat: copy = .logReleasedNotSuited
            case .stopping: copy = .logReleasedStopping
            case .seatDisabled: copy = .logReleasedSwitchedOff
            case .seatRemoved: copy = .logReleasedRemoved
            case nil: copy = .logReleasedOther
            }
            return copy.filled(agent)
        case .taskLeaseExpired: return TaskPageCopy.logLeaseExpired.text
        case .holdOpened: return holdOpenedSentence(event, context)
        case .holdClosed: return holdClosedSentence(event, context)
        case .credentialLimitReached: return limitSentence(event, context)
        case .credentialSignedOut:
            let account = capitalised(context.account(context.credentialID(event)))
            guard let seat = context.uuid(event, "seat_id") else {
                return TaskPageCopy.logSignedOutFound.filled(["account": account])
            }
            return TaskPageCopy.logSignedOutStopped.filled(["account": account, "agent": context.agent(named: seat)])
        case .credentialVerified:
            return TaskPageCopy.logVerified.filled(["account": capitalised(context.account(context.credentialID(event)))])
        case .credentialSwitched:
            let seat = context.agent(named: context.uuid(event, "seat_id"))
            let account = context.account(context.credentialID(event))
            guard let from = context.uuid(event, "from_credential_id") else {
                return TaskPageCopy.logSwitched.filled(["agent": seat, "account": account])
            }
            return TaskPageCopy.logSwitchedFrom.filled(["agent": seat, "account": account, "from": context.account(from)])
        case .inboxOpened: return inboxOpenedSentence(event)
        case .inboxResolved: return inboxResolvedSentence(event)
        case .taskPromoted: return TaskPageCopy.logPromoted.text
        case .taskReturned:
            return (context.returnedWhileHeld.contains(event.id) ? TaskPageCopy.logReturned : .logReturnedNoAgent).text
        case .seatPaused: return TaskPageCopy.logSeatPaused.filled(["agent": context.agent(named: event.subjectID)])
        case .seatResumed: return TaskPageCopy.logSeatResumed.filled(["agent": context.agent(named: event.subjectID)])
        case .seatChanged: return TaskPageCopy.logSeatChanged.filled(["agent": context.agent(named: event.subjectID)])
        default: return TaskPageCopy.logUpdated.text
        }
    }

    private static func capitalised(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }
}
