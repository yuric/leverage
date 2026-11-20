import Foundation
import LeverageKit
import LeverageTestSupport

@testable import LeverageApp

/// Made-up values the Needs you screen's and the inbox watcher's tests share.
enum NeedsYouFixtures {
    static let taskID = UUID(uuidString: "a1a1a1a1-1111-4111-8111-a1a1a1a1a1a1")!
    static let otherTaskID = UUID(uuidString: "a2a2a2a2-2222-4222-8222-a2a2a2a2a2a2")!
    static let credentialID = UUID(uuidString: "c1c1c1c1-1111-4111-8111-c1c1c1c1c1c1")!
    static let requestID = UUID(uuidString: "78787878-7878-4878-8878-787878787878")!
    /// Obviously not a real address; no sentence may ever carry it.
    static let madeUpEmail = "someone@example.invalid"
    static let taskTitle = "Fix the totals on the invoice page"
    static let otherTitle = "Add CSV export to reports"

    static func item(
        _ kind: NeedsYouItem, seq: Int, id: UUID = UUID(), task: UUID? = taskID, credential: UUID? = nil,
        choices: [InboxChoice]? = nil, round: Int = 3
    ) -> InboxItem {
        var facts: [String: JSONValue] = [:]
        if let credential { facts["credential_id"] = .string(credential.contractString) }
        if kind == .pastRoundLimit { facts["round"] = .number(Double(round)) }
        return InboxItem(
            id: id, kind: kind, aboutKind: .task, aboutID: task ?? UUID(), credentialID: credential,
            choices: choices ?? defaultChoices(kind), facts: facts,
            openedAt: Date(timeIntervalSince1970: 1_780_000_000 + Double(seq)), openedSeq: seq)
    }

    static func defaultChoices(_ kind: NeedsYouItem) -> [InboxChoice] {
        switch kind {
        case .accountSignedOut: [.signInAgain]
        case .pastRoundLimit: [.allowAnotherRound, .editContract, .cancel]
        case .approval: [.approve, .stop]
        default: []
        }
    }

    static func signedOut(seq: Int, id: UUID = UUID(), task: UUID = taskID) -> InboxItem {
        item(.accountSignedOut, seq: seq, id: id, task: task, credential: credentialID)
    }

    static func limit(seq: Int, id: UUID = UUID(), task: UUID = taskID) -> InboxItem {
        item(.limitWithNoResetTime, seq: seq, id: id, task: task, credential: credentialID)
    }

    static func pastRound(seq: Int, id: UUID = UUID(), task: UUID = taskID) -> InboxItem {
        item(.pastRoundLimit, seq: seq, id: id, task: task)
    }

    static func board(asOfSeq: Int = 30) -> Board {
        Board(
            tasks: [
                BoardTask(task: summary(taskID, taskTitle)), BoardTask(task: summary(otherTaskID, otherTitle)),
            ], asOfSeq: asOfSeq, reviewerSeatExists: true)
    }

    private static func summary(_ id: UUID, _ title: String) -> TaskSummary {
        TaskSummary(
            id: id, title: title, goal: "g", details: nil, state: .working, round: 0, holderSeatID: nil,
            builderSeatID: nil, workReference: nil, priority: .normal)
    }

    static func credentials(asOfSeq: Int = 31) -> CredentialsList {
        CredentialsList(
            credentials: [
                CredentialWithReading(
                    credential: Credential(
                        id: credentialID, provider: .claude, name: "Personal", accountEmail: madeUpEmail,
                        state: .signedOut, position: 1))
            ], asOfSeq: asOfSeq)
    }

    static func page(_ items: [InboxItem], next: Int? = nil) -> InboxPage {
        InboxPage(items: items, nextAfterSeq: next ?? items.map(\.openedSeq).max() ?? 0)
    }

    /// An owner that answers the board, the credentials and the open items
    /// the test keeps in `open`.
    static func owner(open: Locked<[InboxItem]>, board: Board = board(), credentials: CredentialsList = credentials())
        -> FakeOwnerAPI {
        let owner = FakeOwnerAPI()
        owner.script {
            $0.board = { board }
            $0.credentials = { credentials }
            $0.listInbox = { after, _ in
                page(open.value.filter { $0.openedSeq > (after ?? 0) })
            }
        }
        return owner
    }

    static func opened(
        seq: Int, item: UUID, kind: NeedsYouItem, task: UUID? = taskID
    ) -> EventRecord {
        TaskScreenFixtures.event(
            .inboxOpened, seq: seq, taskID: task, actorKind: .app, subjectKind: .inboxItem, subjectID: item,
            payload: ["kind": .string(kind.rawValue)])
    }

    static func resolved(seq: Int, item: UUID, task: UUID? = taskID) -> EventRecord {
        TaskScreenFixtures.event(
            .inboxResolved, seq: seq, taskID: task, actorKind: .owner, subjectKind: .inboxItem, subjectID: item)
    }

    static func calls(_ owner: FakeOwnerAPI, _ operation: ContractOperation) -> [FakeCall] {
        owner.calls.filter { $0.operation == operation }
    }
}
