import Foundation
import LeverageKit
import LeverageTestSupport

@testable import LeverageApp

/// Made-up values the board, Add task and task page tests share.
enum TaskScreenFixtures {
    static let builderID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    static let reviewerID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!

    static func summary(
        _ state: TaskState = .ready, id: UUID = UUID(), title: String = "Fix the totals on the invoice page",
        goal: String = "The totals are right.", details: String? = nil, holder: UUID? = nil, builder: UUID? = nil,
        round: Int = 0, workReference: String? = nil, priority: Priority = .normal
    ) -> TaskSummary {
        TaskSummary(
            id: id, title: title, goal: goal, details: details, state: state, round: round, holderSeatID: holder,
            builderSeatID: builder, workReference: workReference, priority: priority)
    }

    static func boardTask(
        _ state: TaskState = .ready, id: UUID = UUID(), title: String = "Fix the totals on the invoice page",
        holder: UUID? = nil, builder: UUID? = nil, holds: [HoldReason] = [], waitingFor: UUID? = nil,
        waitingUntil: Date? = nil
    ) -> BoardTask {
        BoardTask(
            task: summary(state, id: id, title: title, holder: holder, builder: builder), blocked: !holds.isEmpty,
            holdReasons: holds, waitingForCredentialID: waitingFor, waitingUntil: waitingUntil)
    }

    static func board(_ tasks: [BoardTask], asOfSeq: Int = 10, reviewer: Bool = true) -> Board {
        Board(tasks: tasks, asOfSeq: asOfSeq, reviewerSeatExists: reviewer)
    }

    static func seat(_ id: UUID, name: String, role: SeatRole = .builder, provider: Provider = .claude) -> Seat {
        Seat(id: id, name: name, provider: provider, role: role)
    }

    static func seats(asOfSeq: Int = 10) -> SeatsList {
        SeatsList(
            seats: [
                seat(builderID, name: "Builder One"),
                seat(reviewerID, name: "Reviewer One", role: .reviewer, provider: .codex),
            ], asOfSeq: asOfSeq)
    }

    /// An owner that answers the board and the seats read with the given values.
    static func owner(board: Board, seats: SeatsList = seats()) -> FakeOwnerAPI {
        let owner = FakeOwnerAPI()
        owner.script {
            $0.board = { board }
            $0.seats = { seats }
        }
        return owner
    }

    static func event(
        _ type: EventType, seq: Int, taskID: UUID? = nil, actor: UUID? = nil, actorKind: ActorKind = .seat,
        subjectKind: EventSubjectKind? = nil, subjectID: UUID? = nil, payload: [String: JSONValue] = [:]
    ) -> EventRecord {
        EventRecord(
            id: UUID(), workspaceID: UUID(), seq: seq, at: Date(timeIntervalSince1970: 1_780_000_000 + Double(seq)),
            type: type, actorKind: actorKind, actorID: actor, taskID: taskID, subjectKind: subjectKind,
            subjectID: subjectID, payload: payload)
    }

    static func page(
        _ task: TaskSummary, criteria: [Criterion] = [], holds: [Hold] = [], events: [EventRecord] = [],
        names: [LogName] = [], reviewer: Bool = true, asOfSeq: Int = 20
    ) -> TaskPage {
        TaskPage(
            task: task, criteria: criteria, holds: holds, events: events, names: names, reviewerSeatExists: reviewer,
            asOfSeq: asOfSeq)
    }

    static func criterion(
        _ text: String, taskID: UUID, position: Int = 1, kind: CriterionKind = .build, state: CriterionState = .open,
        evidence: [CriterionEvidence] = [], id: UUID = UUID()
    ) -> Criterion {
        Criterion(id: id, taskID: taskID, position: position, text: text, kind: kind, state: state, evidence: evidence)
    }

    static func hold(_ reason: HoldReason, taskID: UUID, open: Bool = true) -> Hold {
        Hold(
            id: UUID(), taskID: taskID, reason: reason, openedAt: Date(timeIntervalSince1970: 1_780_000_000),
            closedAt: open ? nil : Date(timeIntervalSince1970: 1_780_000_100))
    }

    static func plain(_ command: CommandName, key: IdempotencyKey) -> PlainOutcome {
        .completed(.object([:]), key: key.value, command: command)
    }
}
