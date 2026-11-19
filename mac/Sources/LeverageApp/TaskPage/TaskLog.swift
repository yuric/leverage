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
    static func entries(events: [EventRecord], names: [LogName], criteria: [Criterion]) -> [LogEntry] {
        let seats = Dictionary(
            names.filter { $0.kind == .seat }.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let words = Dictionary(criteria.map { ($0.id, $0.text) }, uniquingKeysWith: { first, _ in first })
        return events.sorted { $0.seq < $1.seq }.map { event in
            let context = Context(seats: seats, criteria: words)
            return LogEntry(id: event.id, seq: event.seq, at: event.at, text: sentence(for: event, in: context))
        }
    }

    private struct Context {
        let seats: [UUID: String]
        let criteria: [UUID: String]

        func agent(_ event: EventRecord) -> String {
            guard event.actorKind == .seat, let id = event.actorID, let name = seats[id] else {
                return TaskPageCopy.anAgent.text
            }
            return name
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
    }

    private static func sentence(for event: EventRecord, in context: Context) -> String {
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
        case .reviewReleased: return TaskPageCopy.logReviewReleased.filled(agent)
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
        case .holdOpened:
            let reason = event.payload["reason"]?.stringValue.flatMap(HoldReason.init(rawValue:))
            return reason == .roundsExceeded ? TaskPageCopy.logPausedAtLimit.text : TaskPageCopy.logPaused.text
        case .holdClosed: return TaskPageCopy.logNoLongerPaused.text
        default: return TaskPageCopy.logUpdated.text
        }
    }

    private static func capitalised(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }
}
