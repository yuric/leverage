import Foundation
import LeverageKit
import Testing

@testable import LeverageApp

private typealias Fixtures = TaskScreenFixtures

/// The log of a task page: one plain sentence for each event, read from the
/// events and the names the read carries (MA-28, MA-29).
@Suite("TaskLog")
struct TaskLogTests {
    private let taskID = UUID()
    private let builder = Fixtures.builderID
    private let reviewer = Fixtures.reviewerID
    private let criterionID = UUID()
    private let secondID = UUID()

    private var names: [LogName] {
        [
            LogName(kind: .seat, id: builder, name: "Builder One"),
            LogName(kind: .seat, id: reviewer, name: "Reviewer One"),
            LogName(kind: .credential, id: UUID(), name: "Personal"),
        ]
    }

    private var criteria: [Criterion] {
        [
            Fixtures.criterion("Totals match the lines", taskID: taskID, id: criterionID),
            Fixtures.criterion("The page still loads", taskID: taskID, position: 2, id: secondID),
        ]
    }

    private func sentence(_ event: EventRecord) -> String? {
        TaskLog.entries(events: [event], names: names, criteria: criteria).first?.text
    }

    private func event(
        _ type: EventType, actor: UUID? = nil, subject: UUID? = nil, kind: EventSubjectKind? = nil,
        actorKind: ActorKind = .seat, payload: [String: JSONValue] = [:]
    ) -> EventRecord {
        Fixtures.event(
            type, seq: 1, taskID: taskID, actor: actor, actorKind: actorKind, subjectKind: kind, subjectID: subject,
            payload: payload)
    }

    @Test("the entries come in the order of the log, one for each event, with the event's time")
    func order() {
        let events = [
            Fixtures.event(.taskReady, seq: 3, taskID: taskID, actorKind: .owner),
            Fixtures.event(.taskCreated, seq: 1, taskID: taskID, actorKind: .owner),
            Fixtures.event(.taskContractChanged, seq: 2, taskID: taskID, actorKind: .owner),
        ]
        let entries = TaskLog.entries(events: events, names: names, criteria: criteria)
        #expect(entries.map(\.seq) == [1, 2, 3])
        #expect(entries.map(\.at) == events.sorted { $0.seq < $1.seq }.map(\.at))
        #expect(Set(entries.map(\.id)).count == 3)
    }

    @Test("what the owner does reads as 'you'")
    func ownerEvents() {
        #expect(sentence(event(.taskCreated, actorKind: .owner)) == "You added the task.")
        #expect(sentence(event(.taskCancelled, actorKind: .owner)) == "You cancelled the task.")
        #expect(sentence(event(.taskContractChanged, actorKind: .owner)) == "The details were saved.")
        #expect(sentence(event(.taskReady, actorKind: .owner)) == "The task is ready for an agent to pick up.")
    }

    @Test("an event of an agent names the agent from the names of the read")
    func agentEvents() {
        #expect(sentence(event(.taskClaimed, actor: builder)) == "Builder One took the task.")
        #expect(sentence(event(.taskBriefingAcknowledged, actor: builder)) == "Builder One read the briefing.")
        #expect(sentence(event(.taskSubmitted, actor: builder)) == "Builder One handed in the work for review.")
        #expect(sentence(event(.reviewStarted, actor: reviewer)) == "Reviewer One started reviewing the work.")
        #expect(sentence(event(.reviewPassed, actor: reviewer)) == "Reviewer One approved the work.")
        #expect(sentence(event(.taskDone, actorKind: .app)) == "The work passed review. The task is done.")
    }

    @Test("an agent the read has no name for is 'An agent'")
    func unnamedAgent() {
        #expect(sentence(event(.taskClaimed, actor: UUID())) == "An agent took the task.")
        #expect(sentence(event(.taskClaimed, actor: nil)) == "An agent took the task.")
    }

    @Test("a criterion event quotes the criterion's text")
    func criterionEvents() {
        #expect(sentence(event(.criterionStarted, actor: builder, subject: criterionID, kind: .criterion))
            == "Builder One started on “Totals match the lines”.")
        #expect(sentence(event(.criterionPassed, actor: builder, subject: criterionID, kind: .criterion))
            == "Builder One finished “Totals match the lines”.")
        #expect(sentence(event(.criterionReopened, actor: reviewer, subject: criterionID, kind: .criterion))
            == "“Totals match the lines” needs more work.")
        #expect(sentence(event(
            .evidenceAttached, actor: builder, payload: ["criterion_id": .string(criterionID.contractString), "kind": .string("link")]))
            == "Builder One added a link to “Totals match the lines”.")
        #expect(sentence(event(
            .evidenceAttached, actor: builder, payload: ["criterion_id": .string(criterionID.contractString), "kind": .string("note")]))
            == "Builder One added a note to “Totals match the lines”.")
    }

    @Test("a criterion the page no longer has is called 'a part of the task'")
    func missingCriterion() {
        #expect(sentence(event(.criterionPassed, actor: builder, subject: UUID(), kind: .criterion))
            == "Builder One finished a part of the task.")
    }

    @Test("a failed review says what was not done")
    func reviewFailed() {
        let other = criteria[1].id
        let failed = event(
            .reviewFailed, actor: reviewer,
            payload: [
                "failed_criterion_ids": .array([.string(criterionID.contractString), .string(other.contractString)]),
                "failed_rule_check_id": .null, "lease_seat_id": .null, "wait_cause": .null,
            ])
        #expect(sentence(failed)
            == "Reviewer One sent the work back. Not done yet: “Totals match the lines”, “The page still loads”.")
        let bare = event(.reviewFailed, actor: reviewer, payload: ["failed_criterion_ids": .array([])])
        #expect(sentence(bare) == "Reviewer One sent the work back.")
        #expect(sentence(event(.taskReturnedForRework, payload: ["lease_seat_id": .null, "wait_cause": .null]))
            == "The work went back to the builder to fix.")
    }

    @Test("a task that went back to waiting says why, for each reason, and a lease ending is not called that")
    func released() {
        func released(_ reason: String) -> String? {
            sentence(event(.taskReleased, actor: builder, payload: ["reason": .string(reason), "wait_cause": .null]))
        }
        #expect(released("unable_to_continue") == "Builder One could not carry on, so the task went back to waiting.")
        #expect(released("not_suited_to_this_seat") == "Builder One said the task does not suit it, so the task went back to waiting.")
        #expect(released("stopping") == "Builder One was stopped, so the task went back to waiting.")
        #expect(released("seat_disabled") == "Builder One was switched off, so the task went back to waiting.")
        #expect(released("seat_removed") == "Builder One was removed, so the task went back to waiting.")
        #expect(Set(ReleaseReason.allCases.map { released($0.rawValue) ?? "" }).count == ReleaseReason.allCases.count)

        #expect(sentence(event(.taskLeaseExpired, payload: ["wait_cause": .null]))
            == "The agent stopped responding, so the task went back to waiting.")
        #expect(sentence(event(.reviewLeaseExpired))
            == "The reviewer stopped responding, so the review went back to waiting.")
        #expect(sentence(event(.reviewReleased, actor: reviewer))
            == "Reviewer One stepped away from the review. Another reviewer will take it.")
    }

    @Test("the round limit reads 'Sent back too many times. Paused.' and any other pause says the task was paused")
    func holds() {
        func opened(_ reason: HoldReason) -> String? {
            sentence(event(
                .holdOpened, actorKind: .app,
                payload: ["reason": .string(reason.rawValue), "rule_id": .null, "credential_id": .null]))
        }
        #expect(opened(.roundsExceeded) == "Sent back too many times. Paused.")
        #expect(opened(.ownerApproval) == "The task was paused.")
        #expect(sentence(event(
            .holdClosed, actorKind: .owner,
            payload: ["reason": .string("rounds_exceeded"), "rule_id": .null, "credential_id": .null,
                      "lease_seat_id": .null, "wait_cause": .null])) == "The task is no longer paused.")
    }

    @Test("an event the task page has no sentence for yet reads as a general one")
    func fallback() {
        #expect(sentence(event(.questionAsked, actor: builder)) == "The task was updated.")
        #expect(sentence(event(.checkQueued, actorKind: .app)) == "The task was updated.")
    }

    @Test("every event type gets a sentence in plain words, with nothing of the engine's showing")
    func everyEventIsPlain() {
        for type in EventType.allCases {
            let text = sentence(event(
                type, actor: builder, subject: criterionID,
                payload: [
                    "reason": .string("seat_removed"), "kind": .string("link"),
                    "criterion_id": .string(criterionID.contractString),
                    "failed_criterion_ids": .array([.string(criterionID.contractString)]),
                ]))
            let line = text ?? ""
            #expect(!line.isEmpty, "\(type)")
            #expect(BannedTerms.found(in: line).isEmpty, "\(type): \(line)")
            #expect(!line.contains("_") && !line.contains("{"), "\(type): \(line)")
        }
    }
}
