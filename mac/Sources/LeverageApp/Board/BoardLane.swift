import Foundation
import LeverageKit

/// One lane of the board (MA-1): six from a task's state and its holds, and a
/// seventh for cancelled tasks that shows only under Show cancelled.
enum BoardLane: Equatable, Hashable, Sendable, CaseIterable {
    case imaginarium, backlog, blocked, ready, inProgress, done, cancelled

    /// The six lanes the board always draws, Blocked just before Ready.
    static let standard: [BoardLane] = [.imaginarium, .backlog, .blocked, .ready, .inProgress, .done]

    /// The holds that put a task in Blocked: the registry's `in_blocked` ones
    /// (`api/contract/registry.json`, `hold_reasons`), as the generated
    /// `HoldReason.isInBlocked` gives them.
    static let blockingReasons: Set<HoldReason> = Set(HoldReason.allCases.filter(\.isInBlocked))

    /// The lane a task would be in with no hold.
    static func lane(forState state: TaskState) -> BoardLane {
        switch state {
        case .imaginarium: .imaginarium
        case .backlog: .backlog
        case .ready: .ready
        case .working, .inReview, .finishing: .inProgress
        case .done: .done
        case .cancelled: .cancelled
        }
    }

    /// The lane a card is in: Done and Cancelled by state; otherwise Blocked
    /// when it has an open hold that waits on the owner or the project, and
    /// its own state's lane when it has not.
    static func lane(for task: BoardTask) -> BoardLane {
        let state = task.task.state
        if state == .done || state == .cancelled { return lane(forState: state) }
        if task.holdReasons.contains(where: blockingReasons.contains) { return .blocked }
        return lane(forState: state)
    }

    /// The heading the lane is drawn with.
    var heading: BoardCopy {
        switch self {
        case .imaginarium: .laneIdeas
        case .backlog: .laneBacklog
        case .blocked: .laneBlocked
        case .ready: .laneReady
        case .inProgress: .laneInProgress
        case .done: .laneDone
        case .cancelled: .laneCancelled
        }
    }
}

/// A lane with the cards in it, as the board draws it.
struct LaneContent: Identifiable, Equatable, Sendable {
    let lane: BoardLane
    let cards: [BoardCard]

    var id: BoardLane { lane }
    var count: Int { cards.count }
}
