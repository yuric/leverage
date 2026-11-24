import Foundation
import LeverageKit
import Testing

@testable import LeverageApp

/// Which lane a task is in (MA-1): its state, and Blocked for the holds the
/// registry says wait on the owner or the project.
@Suite("BoardLane")
struct BoardLaneTests {
    private func lane(_ state: TaskState, holds: [HoldReason] = []) -> BoardLane {
        BoardLane.lane(for: TaskScreenFixtures.boardTask(state, holds: holds))
    }

    @Test("a task with no hold is in the lane of its state")
    func byState() {
        #expect(lane(.ideas) == .ideas)
        #expect(lane(.backlog) == .backlog)
        #expect(lane(.ready) == .ready)
        #expect(lane(.working) == .inProgress)
        #expect(lane(.inReview) == .inProgress)
        #expect(lane(.finishing) == .inProgress)
        #expect(lane(.done) == .done)
        #expect(lane(.cancelled) == .cancelled)
    }

    @Test("every state has a lane, and the board draws six of them, Blocked just before Ready")
    func sixLanes() {
        for state in TaskState.allCases { _ = lane(state) }
        #expect(BoardLane.standard == [.ideas, .backlog, .blocked, .ready, .inProgress, .done])
        #expect(BoardLane.standard.count == 6)
    }

    @Test("a task with an open hold that waits on the owner is in Blocked, whatever its state")
    func blockedWhateverTheState() {
        for state in [TaskState.ideas, .backlog, .ready, .working, .inReview, .finishing] {
            #expect(lane(state, holds: [.roundsExceeded]) == .blocked, "\(state)")
        }
    }

    @Test("a finished or cancelled task stays where it is, even with a hold still recorded")
    func terminalStatesStay() {
        #expect(lane(.done, holds: [.ownerApproval]) == .done)
        #expect(lane(.cancelled, holds: [.ownerApproval]) == .cancelled)
    }

    @Test("a hold that is not in Blocked leaves the task in its own lane, and one blocking hold among others is enough")
    func holdsThatDoNotBlock() {
        #expect(lane(.backlog, holds: [.contractIncomplete]) == .backlog)
        #expect(lane(.working, holds: [.contractIncomplete, .ownerQuestion]) == .blocked)
    }

    @Test("a task waiting on a provider limit stays in its own lane, In progress when an agent is on it (L697)")
    func waitingOnALimitIsNotBlocked() {
        #expect(lane(.working, holds: [.credentialLimit]) == .inProgress)
        #expect(lane(.inReview, holds: [.credentialLimit]) == .inProgress)
        #expect(lane(.ready, holds: [.credentialLimit]) == .ready)
        #expect(!BoardLane.blockingReasons.contains(.credentialLimit))
        #expect(lane(.working, holds: [.seatPaused]) == .inProgress)
    }

    @Test("a task waiting on a sign-in, or paused by the owner, is in Blocked from every lane it can come from")
    func signedOutAndPausedAreBlocked() {
        for state in [TaskState.backlog, .ready, .working, .inReview] {
            #expect(lane(state, holds: [.credentialSignedOut]) == .blocked, "\(state)")
            #expect(lane(state, holds: [.ownerHold]) == .blocked, "\(state)")
        }
        #expect(lane(.working, holds: [.credentialLimit, .ownerHold]) == .blocked)
    }

    @Test("an idea is in the Ideas lane, and Move to Backlog puts it in Backlog")
    func ideasLane() {
        #expect(lane(.ideas) == .ideas)
        #expect(lane(.backlog) == .backlog)
        #expect(BoardLane.standard.first == .ideas)
    }

    @Test("the holds that block are the registry's in_blocked ones, read from the contract file")
    func matchesTheRegistry() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: root.appending(path: "api/contract/registry.json"))
        let registry = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let rows = try #require(registry["hold_reasons"] as? [[String: Any]])
        var fromRegistry = Set<HoldReason>()
        for row in rows where (row["in_blocked"] as? Bool) == true {
            let name = try #require(row["reason"] as? String)
            fromRegistry.insert(try #require(HoldReason(rawValue: name), "\(name)"))
        }
        #expect(!fromRegistry.isEmpty)
        #expect(fromRegistry == BoardLane.blockingReasons)
        #expect(Set(HoldReason.allCases.filter(\.isInBlocked)) == fromRegistry)
        #expect(rows.count == HoldReason.allCases.count)
    }

    @Test("each lane has the heading the mockup gives it")
    func headings() {
        #expect(BoardLane.ideas.heading.text == "Ideas")
        #expect(BoardLane.backlog.heading.text == "Backlog")
        #expect(BoardLane.blocked.heading.text == "Blocked")
        #expect(BoardLane.ready.heading.text == "Ready")
        #expect(BoardLane.inProgress.heading.text == "In progress")
        #expect(BoardLane.done.heading.text == "Done")
        #expect(BoardLane.cancelled.heading.text == "Cancelled")
    }
}
