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

/// What the log tells of an interruption, a handoff, a wait and a continuation
/// (HM-43, inventory §11.5): one plain sentence for each, and "back at work
/// after <duration>" when it ended.
@Suite("TaskLog handoff")
struct TaskLogHandoffTests {
    private let taskID = UUID()
    private let builder = Fixtures.builderID
    private let reviewer = Fixtures.reviewerID
    private let personal = Fixtures.personalID
    private let work = Fixtures.workID
    private let clock = Fixtures.clock()

    private var names: [LogName] {
        [
            LogName(kind: .seat, id: builder, name: "Builder One"),
            LogName(kind: .seat, id: reviewer, name: "Reviewer One"),
            LogName(kind: .credential, id: personal, name: "Personal"),
            LogName(kind: .credential, id: work, name: "Work"),
        ]
    }

    private func entries(_ events: [EventRecord], recovery: [RecoveryTime] = [], accounts: [UUID: String] = [:]) -> [String] {
        TaskLog.entries(events: events, names: names, criteria: [], recoveryTimes: recovery, accounts: accounts, clock: clock)
            .map { Fixtures.flat($0.text) }
    }

    private func sentence(
        _ type: EventType, actor: UUID? = nil, actorKind: ActorKind = .app, subject: UUID? = nil,
        kind: EventSubjectKind? = nil, payload: [String: JSONValue] = [:], accounts: [UUID: String] = [:]
    ) -> String? {
        let event = Fixtures.event(
            type, seq: 5, taskID: taskID, actor: actor, actorKind: actorKind, subjectKind: kind, subjectID: subject,
            payload: payload)
        return entries([event], accounts: accounts).first
    }

    private func id(_ value: UUID) -> JSONValue { .string(value.contractString) }

    // MARK: an interruption

    @Test("a limit reached names the account, the window and when it resets")
    func limitReached() {
        let limit = { (window: JSONValue, reset: JSONValue) in
            self.sentence(
                .credentialLimitReached, subject: self.personal, kind: .credential,
                payload: ["seat_id": self.id(self.builder), "review_id": .null, "job_id": .null, "window": window, "reset_at": reset])
        }
        #expect(limit(.string("weekly"), .string("2026-11-19T18:00:00Z")) == "Personal reached its weekly limit. It resets at 6:00 PM.")
        #expect(limit(.string("five_hour"), .string("2026-11-20T09:30:00.000Z")) == "Personal reached its five-hour limit. It resets at Friday 9:30 AM.")
        #expect(limit(.string("per_model"), .null) == "Personal reached its limit for one model.")
        #expect(limit(.string("spend"), .null) == "Personal reached its spending limit.")
        #expect(limit(.null, .null) == "Personal reached its limit.")
        #expect(limit(.string("weekly"), .string("not a time")) == "Personal reached its weekly limit.")
    }

    @Test("an account is named as the owner knows it when the read says which provider it is for")
    func accountNames() {
        #expect(sentence(
            .credentialLimitReached, subject: personal, kind: .credential,
            payload: ["window": .string("weekly")], accounts: [personal: "Claude, Personal"])
            == "Claude, Personal reached its weekly limit.")
        #expect(sentence(.credentialLimitReached, subject: UUID(), kind: .credential, payload: [:])
            == "An account reached its limit.")
    }

    @Test("a sign-out says which account, and whether an agent was on it")
    func signedOut() {
        #expect(sentence(.credentialSignedOut, subject: personal, kind: .credential, payload: ["seat_id": id(builder)])
            == "Personal was signed out, so Builder One stopped.")
        #expect(sentence(.credentialSignedOut, subject: personal, kind: .credential, payload: ["seat_id": .null])
            == "Personal was found signed out when it was checked.")
        #expect(sentence(.credentialVerified, subject: personal, kind: .credential) == "Personal was signed in again.")
    }

    // MARK: a handoff and a continuation

    @Test("a handoff says which agent went on, on which account, and from which")
    func switched() {
        #expect(sentence(.credentialSwitched, subject: work, kind: .credential, payload: ["seat_id": id(builder), "from_credential_id": id(personal)])
            == "Builder One moved from Personal to Work and went on from the saved work.")
        #expect(sentence(.credentialSwitched, subject: work, kind: .credential, payload: ["seat_id": id(builder), "from_credential_id": .null])
            == "Builder One went on with Work from the saved work.")
    }

    // MARK: waiting

    @Test("a task that waits for an account says which, when it waits for a limit or for a sign-in")
    func waiting() {
        func opened(_ reason: HoldReason, credential: UUID? = nil) -> String? {
            sentence(.holdOpened, payload: ["reason": .string(reason.rawValue), "rule_id": .null, "credential_id": credential.map(id) ?? .null])
        }
        func closed(_ reason: HoldReason, credential: UUID? = nil, cause: String? = nil, actorKind: ActorKind = .app) -> String? {
            sentence(.holdClosed, actorKind: actorKind, payload: [
                "reason": .string(reason.rawValue), "rule_id": .null, "credential_id": credential.map(id) ?? .null,
                "lease_seat_id": .null, "wait_cause": cause.map { .string($0) } ?? .null,
            ])
        }
        #expect(opened(.credentialLimit, credential: personal) == "The task is waiting for Personal to be available again.")
        #expect(opened(.credentialLimit) == "The task is waiting for an account to be available again.")
        #expect(opened(.credentialSignedOut, credential: personal) == "The task is paused until Personal is signed in again.")
        #expect(opened(.ownerHold) == "You paused the task.")
        #expect(opened(.seatPaused) == "The agent working on the task was paused, so it is waiting.")
        #expect(opened(.roundsExceeded) == "Sent back too many times. Paused.")
        #expect(opened(.ownerApproval) == "The task was paused.")

        #expect(closed(.credentialLimit, credential: personal) == "Personal is available again, so the task goes on.")
        #expect(closed(.credentialSignedOut, credential: personal) == "Personal is signed in again, so the task goes on.")
        #expect(closed(.ownerHold, actorKind: .owner) == "You continued the task.")
        #expect(closed(.seatPaused) == "The agent was resumed, so the task goes on.")
        #expect(closed(.roundsExceeded, actorKind: .owner) == "The task is no longer paused.")
        #expect(closed(.credentialLimit, credential: personal, cause: "credential_limit")
            == "Personal is available again, so the task goes on. It is waiting for an account to be available.")
    }

    @Test("a task that went back to waiting because no account was free says so")
    func waitsForAnAccount() {
        #expect(sentence(.taskReleased, actor: builder, actorKind: .seat, payload: ["reason": .string("stopping"), "wait_cause": .string("credential_limit")])
            == "Builder One was stopped, so the task went back to waiting. It is waiting for an account to be available.")
        #expect(sentence(.taskLeaseExpired, payload: ["wait_cause": .string("credential_limit")])
            == "The agent stopped responding, so the task went back to waiting. It is waiting for an account to be available.")
        #expect(sentence(.taskLeaseExpired, payload: ["wait_cause": .null])
            == "The agent stopped responding, so the task went back to waiting.")
    }

    @Test("a review that stopped because of an account says which, from the event that caused it")
    func reviewStopped() {
        let cause = Fixtures.event(
            .credentialLimitReached, seq: 3, taskID: taskID, subjectKind: .credential, subjectID: personal,
            payload: ["window": .string("weekly")])
        let signedOut = Fixtures.event(
            .credentialSignedOut, seq: 3, taskID: taskID, subjectKind: .credential, subjectID: work, payload: [:])
        func released(by cause: EventRecord) -> [String] {
            let event = EventRecord(
                id: UUID(), workspaceID: UUID(), seq: 4, at: cause.at, type: .reviewReleased, actorKind: .app,
                taskID: taskID, causeID: cause.id)
            return entries([cause, event])
        }
        #expect(released(by: cause).last == "The review stopped because Personal reached its limit. Another account will take it.")
        #expect(released(by: signedOut).last == "The review stopped because Work was signed out. Another account will take it.")
        #expect(sentence(.reviewReleased, actor: reviewer, actorKind: .seat)
            == "Reviewer One stepped away from the review. Another reviewer will take it.")
    }

    // MARK: Needs you items

    @Test("an item that opens or settles reads as what needs the owner, and what the owner chose")
    func items() {
        func opened(_ kind: NeedsYouItem) -> String? { sentence(.inboxOpened, payload: ["kind": .string(kind.rawValue)]) }
        func resolved(_ choice: String?) -> String? {
            sentence(.inboxResolved, actorKind: .owner, payload: ["choice": choice.map { .string($0) } ?? .null])
        }
        #expect(opened(.accountSignedOut) == "An account is signed out. This needs you: sign in again.")
        #expect(opened(.limitWithNoResetTime) == "An account is at its limit and did not say when it is available again. This needs you.")
        #expect(opened(.pastRoundLimit) == "The task was sent back too many times. This needs you.")
        #expect(opened(.approval) == "This needs you.")
        #expect(resolved("allow_another_round") == "You let it try once more.")
        #expect(resolved("edit_contract") == "You changed the task.")
        #expect(resolved("cancel") == "You cancelled the task.")
        #expect(resolved("sign_in_again") == "You signed in again.")
        #expect(resolved(nil) == "That no longer needs you.")
        #expect(resolved("answer") == "That no longer needs you.")
    }

    // MARK: what the owner did

    @Test("moving an idea, changing a contract and an agent paused, resumed or changed each get a sentence")
    func ownerAndAgent() {
        #expect(sentence(.taskPromoted, actorKind: .owner) == "You moved the idea to Backlog.")
        #expect(sentence(.taskReturned, actorKind: .owner) == "The agent stopped and the task went back to Backlog.")
        #expect(sentence(.taskContractChanged, actorKind: .owner) == "The details were saved.")
        #expect(sentence(.seatPaused, actorKind: .owner, subject: builder, kind: .seat) == "Builder One was paused.")
        #expect(sentence(.seatResumed, actorKind: .owner, subject: builder, kind: .seat) == "Builder One was resumed.")
        #expect(sentence(.seatChanged, actorKind: .owner, subject: builder, kind: .seat) == "Builder One was changed.")
        #expect(sentence(.seatPaused, actorKind: .owner) == "An agent was paused.")
    }

    // MARK: recovery times

    private func limitEvent(at seq: Int = 5, effective: Date? = nil) -> EventRecord {
        EventRecord(
            id: UUID(), workspaceID: UUID(), seq: seq, at: Fixtures.date(19, 9), effectiveAt: effective ?? Fixtures.date(19, 9),
            type: .credentialLimitReached, actorKind: .app, taskID: taskID, subjectKind: .credential, subjectID: personal,
            payload: ["window": .string("weekly"), "seat_id": id(builder)])
    }

    private func recovery(
        kind: RecoveryKind = .limit, seconds: Int?, endedBy: RecoveryEndedBy?, ended: Bool = true,
        credential: UUID? = nil, review: UUID? = nil
    ) -> RecoveryTime {
        RecoveryTime(
            kind: kind, credentialID: credential ?? personal, reviewID: review, startedAt: Fixtures.date(19, 9),
            endedAt: ended ? Fixtures.date(19, 9).addingTimeInterval(TimeInterval(seconds ?? 0)) : nil, seconds: seconds,
            endedBy: endedBy)
    }

    @Test("an interruption that ended says how long the work was stopped")
    func backAtWork() {
        let event = limitEvent()
        #expect(entries([event], recovery: [recovery(seconds: 1500, endedBy: .seatEvent)])
            == ["Personal reached its weekly limit. Back at work after 25 minutes."])
        #expect(entries([event], recovery: [recovery(seconds: 0, endedBy: .handoff)])
            == ["Personal reached its weekly limit. Back at work at once."])
        #expect(entries([event], recovery: [recovery(seconds: 3900, endedBy: .seatEvent)])
            == ["Personal reached its weekly limit. Back at work after 1 hour 5 minutes."])
    }

    @Test("an interruption that has not ended says the work is not back yet, and one that never did says the task ended first")
    func notBackYet() {
        let event = limitEvent()
        #expect(entries([event], recovery: [recovery(seconds: 600, endedBy: nil, ended: false)])
            == ["Personal reached its weekly limit. Not back at work yet."])
        #expect(entries([event], recovery: [recovery(seconds: nil, endedBy: .notRecovered, ended: false)])
            == ["Personal reached its weekly limit. The task ended before the work started again."])
    }

    @Test("a recovery time is joined to its own interruption, by kind, account and start, and to no other")
    func joinedToItsOwn() {
        let event = limitEvent()
        let other = [
            recovery(kind: .signedOut, seconds: 60, endedBy: .seatEvent),
            recovery(seconds: 60, endedBy: .seatEvent, credential: work),
            RecoveryTime(
                kind: .limit, credentialID: personal, startedAt: Fixtures.date(19, 8), endedAt: Fixtures.date(19, 9), seconds: 60,
                endedBy: .seatEvent),
        ]
        #expect(entries([event], recovery: other) == ["Personal reached its weekly limit."])
    }

    @Test("a sign-out of an agent's run is joined to its recovery time, and the second of two limits to the second")
    func signedOutAndTwoLimits() {
        let signedOut = EventRecord(
            id: UUID(), workspaceID: UUID(), seq: 6, at: Fixtures.date(19, 9), effectiveAt: Fixtures.date(19, 9), type: .credentialSignedOut,
            actorKind: .app, taskID: taskID, subjectKind: .credential, subjectID: personal, payload: ["seat_id": id(builder)])
        #expect(entries([signedOut], recovery: [recovery(kind: .signedOut, seconds: 120, endedBy: .seatEvent)])
            == ["Personal was signed out, so Builder One stopped. Back at work after 2 minutes."])

        let first = limitEvent(at: 5, effective: Fixtures.date(19, 9))
        let second = limitEvent(at: 9, effective: Fixtures.date(19, 10))
        let times = [
            recovery(seconds: 0, endedBy: .handoff),
            RecoveryTime(kind: .limit, credentialID: personal, startedAt: Fixtures.date(19, 10), endedAt: Fixtures.date(19, 10, 25), seconds: 1500, endedBy: .seatEvent),
        ]
        #expect(entries([first, second], recovery: times) == [
            "Personal reached its weekly limit. Back at work at once.",
            "Personal reached its weekly limit. Back at work after 25 minutes.",
        ])
    }

    @Test("a duration is in seconds, minutes, or hours and minutes")
    func durations() {
        #expect(DurationWords.text(seconds: 0) == "0 seconds")
        #expect(DurationWords.text(seconds: 1) == "1 second")
        #expect(DurationWords.text(seconds: 45) == "45 seconds")
        #expect(DurationWords.text(seconds: 60) == "1 minute")
        #expect(DurationWords.text(seconds: 119) == "1 minute")
        #expect(DurationWords.text(seconds: 1500) == "25 minutes")
        #expect(DurationWords.text(seconds: 3600) == "1 hour")
        #expect(DurationWords.text(seconds: 3900) == "1 hour 5 minutes")
        #expect(DurationWords.text(seconds: 7200) == "2 hours")
        #expect(DurationWords.text(seconds: 7260) == "2 hours 1 minute")
        #expect(DurationWords.text(seconds: -5) == "0 seconds")
    }

    // MARK: every sentence is plain

    @Test("no sentence of the handoff uses a banned word, an engine name, an email or 'Nothing was lost'")
    func plainWords() {
        var lines: [String] = []
        let payloads: [[String: JSONValue]] = [
            [:], ["reason": .string("credential_limit"), "credential_id": id(personal), "wait_cause": .string("credential_limit"),
                  "window": .string("weekly"), "reset_at": .string("2026-11-19T18:00:00Z"), "seat_id": id(builder),
                  "from_credential_id": id(work), "kind": .string("account_signed_out"), "choice": .string("sign_in_again")],
            ["reason": .string("owner_hold")], ["reason": .string("seat_paused")], ["reason": .string("credential_signed_out"), "credential_id": id(personal)],
        ]
        for type in EventType.allCases {
            for payload in payloads {
                let event = Fixtures.event(type, seq: 5, taskID: taskID, actor: builder, subjectKind: .credential, subjectID: personal, payload: payload)
                lines += entries([event], recovery: [recovery(seconds: 60, endedBy: .seatEvent)])
            }
        }
        #expect(!lines.isEmpty)
        for line in lines {
            #expect(BannedTerms.found(in: line).isEmpty, "\(line)")
            #expect(!line.contains("_") && !line.contains("{") && !line.contains("@"), "\(line)")
            #expect(!line.localizedCaseInsensitiveContains("Nothing was lost"), "\(line)")
        }
        for copy in TaskPageCopy.allCases {
            #expect(!copy.text.localizedCaseInsensitiveContains("Nothing was lost"), "\(copy.text)")
        }
        for copy in BoardCopy.allCases {
            #expect(!copy.text.localizedCaseInsensitiveContains("Nothing was lost"), "\(copy.text)")
        }
    }

    @Test("each event of milestone 3 has a sentence of its own, not the general one")
    func noGeneralSentence() {
        let types: [EventType] = [
            .credentialLimitReached, .credentialSignedOut, .credentialSwitched, .credentialVerified, .holdOpened, .holdClosed,
            .inboxOpened, .inboxResolved, .reviewReleased, .taskPromoted, .taskContractChanged, .taskReturned, .seatPaused,
            .seatResumed, .seatChanged, .taskReleased,
        ]
        for type in types {
            let line = sentence(type, subject: personal, kind: .credential, payload: ["reason": .string("owner_hold")])
            #expect(line != nil && line != "The task was updated.", "\(type)")
        }
    }
}
