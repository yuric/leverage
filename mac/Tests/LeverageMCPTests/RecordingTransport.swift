import Foundation
import LeverageKit
@testable import LeverageMCP

let taskID = "10000000-0000-4000-8000-000000000001"
let otherTaskID = "10000000-0000-4000-8000-000000000002"
let reviewID = "20000000-0000-4000-8000-000000000001"
let criterionID = "30000000-0000-4000-8000-000000000001"
let actionID = "40000000-0000-4000-8000-000000000001"

actor RecordingTransport {
    private(set) var requests: [ToolRequest] = []
    private var replies: [ToolResponse]

    init(_ replies: [ToolResponse] = []) {
        self.replies = replies
    }

    func send(_ request: ToolRequest) async -> ToolResponse {
        requests.append(request)
        if !replies.isEmpty { return replies.removeFirst() }
        return completed()
    }
}

func completed(_ result: JSONValue = .null) -> ToolResponse {
    ToolResponse(status: 200, body: .object(["outcome": .string("completed"), "result": result]))
}

func refused(_ code: RefusalCode) -> ToolResponse {
    ToolResponse(status: 409, body: .object([
        "outcome": .string("refused"), "refusal": .object(["code": .string(code.rawValue)])
    ]))
}

func claim(_ id: String, kind: String = "task") -> ToolResponse {
    completed(.object([kind: .object(["id": .string(id)])]))
}

func nextItem(_ kind: NextKind, task: String? = nil, review: String? = nil) -> ToolResponse {
    ToolResponse(status: 200, body: .object([
        "kind": .string(kind.rawValue),
        "id": task.map(JSONValue.string) ?? .null,
        "review_id": review.map(JSONValue.string) ?? .null,
    ]))
}

func briefing(actionState: String) -> ToolResponse {
    ToolResponse(status: 200, body: .object([
        "briefing": .object(["contract": .object([
            "actions": .array([.object(["id": .string(actionID), "state": .string(actionState)])])
        ])])
    ]))
}
