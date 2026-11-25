import Foundation
import LeverageKit

/// What a builder does after its task's outward actions are approved.
struct FinishingFlow: Sendable {
    let context: FlowContext

    func continueTask(_ taskID: UUID, acknowledgement: Acknowledgement = .always) async throws -> FlowEnd {
        // The owner can return the work between the poll and the briefing
        // read. The fresh briefing decides which work the lease is for.
        try await BuilderFlow(context: context).continueTask(taskID, acknowledgement: acknowledgement)
    }

    /// A resume, a changed briefing or a helper's continuation names only
    /// the task. Approved and started actions belong to Finishing.
    static func hasApprovedWork(_ briefing: Briefing) -> Bool {
        briefing.contract.actions.contains { $0.state == .approved || $0.state == .started }
    }

    func perform(_ taskID: UUID, _ response: BriefingResponse, acknowledge: Bool) async throws -> BuilderFlow.Step {
        let api = context.api
        let briefing = response.briefing
        if acknowledge, let step = try await context.builderStep(context.command("acknowledge_task_briefing", {
            try await api.acknowledgeTaskBriefing(taskID: taskID, briefingHash: briefing.hash, key: $0)
        }), taskID: taskID) { return step }

        let actions = briefing.contract.actions
        // Once any action was started, only the owner can settle what
        // happened. The runner must not repeat it or start another action.
        guard !actions.contains(where: { $0.state == .started }) else {
            return .end(try await context.releaseBuilderTask(taskID))
        }
        let approved = actions.filter { $0.state == .approved }.sorted { $0.position < $1.position }
        guard !approved.isEmpty else { return .end(.finished) }
        guard let folder = WorkFolder.reviewer(reference: response.workReference, places: context.places) else {
            return .end(try await context.releaseBuilderTask(taskID))
        }

        for action in approved {
            if let step = try await perform(action, taskID: taskID, contract: briefing.contract, folder: folder) {
                return step
            }
        }
        return .end(.finished)
    }

    private func perform(_ action: Action, taskID: UUID, contract: BriefingContract, folder: URL) async throws
        -> BuilderFlow.Step? {
        let api = context.api
        try Task.checkCancellation()
        if let step = try await context.builderStep(context.command("start_action", {
            try await api.startAction(taskID: taskID, actionID: action.id, key: $0)
        }), taskID: taskID) { return step }

        let nonce = JobPrompts.makeNonce()
        let prompt = Prompts.action(contract: contract, action: action, nonce: nonce)
        // A possibly completed outward action must never be attempted
        // again, including on the build flow's short rate-limit path.
        switch try await context.runBuilderTool(taskID: taskID, prompt: prompt, folder: folder, retryInPlace: false) {
        case .step(let step):
            return step
        case .tool(.accountStopped(let report)):
            return .end(.accountStopped(report))
        case .tool(.failed):
            context.state.toolFailed()
        case .tool(.answered(let answer)):
            switch ActionResultParser.parse(answer.text, nonce: nonce) {
            case .done:
                context.state.toolAnswered()
                try Task.checkCancellation()
                return try await context.builderStep(context.command("report_action_done", {
                    try await api.reportActionDone(taskID: taskID, actionID: action.id, key: $0)
                }), taskID: taskID)
            case .cannot:
                context.state.toolAnswered()
            case nil:
                context.state.toolFailed()
            }
        }
        return .end(try await context.releaseBuilderTask(taskID))
    }
}
