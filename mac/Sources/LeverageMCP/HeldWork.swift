import Foundation
import LeverageKit

/// The work the API has accepted for the seat, and the starts seen under
/// that lease. A job has no heartbeat tool.
struct HeldWork {
    enum Item: Equatable {
        case task(String)
        case review(String)

        var heartbeat: ToolRequest {
            switch self {
            case .task(let id): ToolRequest(operation: .heartbeatTask, path: ["id": id], key: IdempotencyKey())
            case .review(let id): ToolRequest(operation: .heartbeatReview, path: ["id": id], key: IdempotencyKey())
            }
        }
    }

    private(set) var item: Item?
    private var startedCriteria: Set<String> = []
    private var startedActions: Set<String> = []
    private var actionStates: [String: ActionState]?
    private var pending: [String: ToolRequest] = [:]
    private var settledKeys: Set<String> = []

    func hasStartedCriterion(task: String, criterion: String) -> Bool {
        item == .task(task) && startedCriteria.contains(criterion)
    }

    func hasStartedAction(task: String, action: String) -> Bool {
        item == .task(task) && startedActions.contains(action)
    }

    func knows(_ key: IdempotencyKey) -> Bool {
        settledKeys.contains(key.value) || pending[key.value] != nil
    }

    /// A stored outcome might describe an earlier lease. It can be returned
    /// to the caller, but it cannot change the work we believe is held now.
    mutating func ignoreStoredOutcome(for key: IdempotencyKey) {
        settledKeys.insert(key.value)
    }

    static func tracksCommand(_ request: ToolRequest) -> Bool {
        request.operation.method == .post &&
            (work(for: request) != nil || request.operation == .claimNextTask || request.operation == .claimNextReview)
    }

    mutating func observe(_ request: ToolRequest, response: ToolResponse) {
        if request.operation == .getCommand {
            guard response.status == 200, let key = request.path["key"],
                  response.body["outcome"]?.stringValue != OutcomeKind.pending.rawValue,
                  let original = pending.removeValue(forKey: key) else { return }
            settledKeys.insert(key)
            settle(original, response: response)
            return
        }

        if Self.tracksCommand(request), let key = request.key?.value {
            guard !settledKeys.contains(key) else { return }
            switch response.status {
            case 202:
                // Polls of known pending commands can settle a lease. Keep
                // only the command and path, without its content.
                pending[key] = ToolRequest(operation: request.operation, path: request.path)
                return
            case 200, 409:
                pending.removeValue(forKey: key)
                settledKeys.insert(key)
            default:
                break
            }
        }
        settle(request, response: response)
    }

    private mutating func settle(_ request: ToolRequest, response: ToolResponse) {
        let target = Self.work(for: request)
        if let code = response.refusalCode, target == item {
            // A work call can refuse the action or question without ending its lease.
            let heartbeat = request.operation == .heartbeatTask || request.operation == .heartbeatReview
            if code == .leaseExpired || code == .taskCancelled ||
                (heartbeat && (code == .notHolder || code == .invalidState)) {
                hold(nil)
            }
        }
        guard response.status == 200, response.body["outcome"]?.stringValue != OutcomeKind.refused.rawValue else {
            return
        }

        switch request.operation {
        case .getNext:
            recordNext(response.body)
        case .claimNextTask:
            guard let id = Self.id(response.body["result"]?["task"]?["id"]) else { return }
            hold(.task(id))
            readBriefing(response.body["result"]?["briefing"])
        case .claimNextReview:
            guard let id = Self.id(response.body["result"]?["review"]?["id"]) else { return }
            hold(.review(id))
        case .submitTask, .releaseTask, .giveVerdict, .releaseReview:
            if target == item { hold(nil) }
        default:
            guard let target else { return }
            hold(target)
            if case .task = target { recordTaskCall(request, body: response.body) }
        }
    }

    private mutating func recordNext(_ body: JSONValue) {
        guard let kind = body["kind"]?.stringValue.flatMap(NextKind.init(rawValue:)),
              let task = Self.id(body["id"]) else { return }
        switch kind {
        case .action, .rework:
            hold(.task(task), fresh: true)
        case .resume:
            hold(.task(task))
        case .briefingChanged:
            if let review = Self.id(body["review_id"]) {
                hold(.review(review))
            } else if body["review_id"] == nil || body["review_id"] == .null {
                hold(.task(task))
            }
        default:
            // Offers and command or question notifications do not identify a lease.
            break
        }
    }

    private mutating func recordTaskCall(_ request: ToolRequest, body: JSONValue) {
        switch request.operation {
        case .getTaskBriefing:
            readBriefing(body["briefing"])
        case .startCriterion:
            if let id = request.path["cid"] { startedCriteria.insert(id) }
        case .passCriterion:
            if let id = request.path["cid"] { startedCriteria.remove(id) }
        case .startAction:
            if let id = request.path["aid"] {
                startedActions.insert(id)
                actionStates?[id] = .started
            }
        case .reportActionDone:
            if let id = request.path["aid"], actionStates?[id] != nil {
                actionStates?[id] = .done
                if actionStates?.values.allSatisfy({ $0 == .done || $0 == .waived }) == true {
                    hold(nil)
                }
            }
        default:
            break
        }
    }

    private mutating func hold(_ next: Item?, fresh: Bool = false) {
        guard fresh || item != next else { return }
        item = next
        startedCriteria.removeAll()
        startedActions.removeAll()
        actionStates = nil
    }

    private mutating func readBriefing(_ briefing: JSONValue?) {
        if let criteria = briefing?["contract"]?["criteria"]?.arrayValue {
            startedCriteria = Set(criteria.compactMap {
                $0["state"]?.stringValue == CriterionState.started.rawValue ? Self.id($0["id"]) : nil
            })
        }
        if let actions = briefing?["contract"]?["actions"]?.arrayValue {
            var states: [String: ActionState] = [:]
            for action in actions {
                guard let id = Self.id(action["id"]),
                      let state = action["state"]?.stringValue.flatMap(ActionState.init(rawValue:)) else { continue }
                states[id] = state
            }
            startedActions = Set(states.filter { $0.value == .started }.keys)
            actionStates = states.count == actions.count ? states : nil
        }
    }

    private static func work(for request: ToolRequest) -> Item? {
        guard let id = request.path["id"] else { return nil }
        switch request.operation {
        case .getTaskBriefing, .acknowledgeTaskBriefing, .heartbeatTask, .startCriterion, .passCriterion,
             .askQuestion, .getQuestion, .requestAccess, .reportCost, .submitTask, .startAction, .reportActionDone,
             .releaseTask:
            return .task(id)
        case .getReviewBriefing, .acknowledgeReviewBriefing, .heartbeatReview, .releaseReview, .giveVerdict:
            return .review(id)
        default:
            return nil
        }
    }

    private static func id(_ value: JSONValue?) -> String? {
        value?.stringValue.flatMap(UUID.init(uuidString:))?.contractString
    }
}
