import Foundation
import LeverageKit

/// How a flow ended.
enum FlowEnd: Equatable, Sendable {
    /// Submitted, or the verdict given.
    case finished
    /// Given back: a failed tool run, an unusable work folder, a refusal
    /// nothing else answers.
    case released
    /// On hold: the work is still held, and `resume` or `rework` continues it.
    case paused
    /// The lease or the task is gone (`lease_expired`, `task_cancelled`,
    /// `not_holder`): nothing to release.
    case ended
    /// The account stopped (a limit or a sign-out): nothing is released,
    /// and the run ends with this report (HD-6).
    case accountStopped(RunEndReport)
}

extension FlowEnd {
    /// The end's kind alone, for a log line.
    var name: String {
        switch self {
        case .finished: "finished"
        case .released: "released"
        case .paused: "paused"
        case .ended: "ended"
        case .accountStopped(let report): "the account stopped (\(report.kind.rawValue))"
        }
    }
}

/// When a flow acknowledges the briefing.
enum Acknowledgement: Sendable {
    /// Before the first criterion, as milestone 2 does after a claim, a
    /// rework, a resume and a changed briefing.
    case always
    /// Only once a call is refused `briefing_not_acknowledged` or
    /// `briefing_changed`: a run started to continue work whose lease did
    /// not change (HD-9).
    case whenAsked
}

/// A builder's work on one task: claim (or a rework, a resume, a changed
/// briefing), acknowledge the briefing, then for every builder criterion
/// not yet passed announce it, drive the tool once, and pass it with the
/// evidence the tool named; then submit (inventory §2.2, trace 09).
struct BuilderFlow: Sendable {
    let context: FlowContext

    /// How many times a flow reads its briefing again before it gives the
    /// task back.
    static let maximumRestarts = 3

    static let handoffNote = "Done; the evidence attached to each criterion shows where its proof is."

    /// How many times a submit a rule refused is reworked by the tool before
    /// the task is given back: the server's re-run limit (RD-45, RD-59)
    /// holds the fourth distinct try for the owner, so a fourth refusal
    /// means something else refuses it.
    static let maximumRuleReworks = 3

    /// Claims the next task and works on it; nil when nothing was claimed.
    func claim() async throws -> FlowEnd? {
        let api = context.api
        guard case .completed(let claim?) = try await context.command("claim_next_task", {
            try await api.claimNextTask(key: $0)
        }) else { return nil }
        context.log.info("claimed task \(claim.task.id.contractString)")
        // A task past round 0 was sent back by a review: the claim's answer
        // carries no review notes, so the first step reads the briefing,
        // which does (PRD L127, L493).
        let start = claim.task.round > 0
            ? nil : BriefingResponse(briefing: claim.briefing, workReference: claim.workReference)
        return try await work(claim.task.id, start: start, leaseDue: claim.lease.leaseDueAt)
    }

    /// Goes on with a task this seat holds, from its briefing: on `rework`,
    /// `resume` and `briefing_changed` acknowledging it first, and at the
    /// start of a run that continues the task only when asked (HD-9).
    func continueTask(_ taskID: UUID, acknowledgement: Acknowledgement = .always) async throws -> FlowEnd {
        try await work(taskID, start: nil, leaseDue: nil, acknowledgement: acknowledgement)
    }

    private func work(
        _ taskID: UUID, start: BriefingResponse?, leaseDue: Date?, acknowledgement: Acknowledgement = .always
    ) async throws -> FlowEnd {
        context.state.hold(.task(taskID))
        let end = try await Heartbeat.around(.task(taskID), leaseDue: leaseDue, context: context) {
            try await steps(taskID, start: start, acknowledgement: acknowledgement)
        }
        if end != .paused { context.state.hold(.nothing) }
        if case .accountStopped(let report) = end { context.state.accountStopped(report) }
        context.log.info("task \(taskID.contractString): \(end.name)")
        return end
    }

    private enum Step {
        case end(FlowEnd)
        /// Read the briefing again; `acknowledge` when the refusal asked for
        /// an acknowledgement.
        case restart(acknowledge: Bool)
    }

    private func steps(_ taskID: UUID, start: BriefingResponse?, acknowledgement: Acknowledgement) async throws
        -> FlowEnd {
        let api = context.api
        var briefing = start
        var restarts = 0
        var acknowledge = acknowledgement == .always
        while true {
            let current: BriefingResponse
            if let briefing {
                current = briefing
            } else {
                switch try await context.read("get_task_briefing", { try await api.taskBriefing(taskID: taskID) }) {
                case .value(let read): current = read
                case .refused(let code):
                    switch try await answer(code, taskID) {
                    case .end(let end): return end
                    case .restart(let asked):
                        acknowledge = acknowledge || asked
                        restarts += 1
                        if restarts > Self.maximumRestarts { return try await release(taskID) }
                        try await Task.sleep(for: context.timing.errorPause)
                        continue
                    }
                case .gone: return .ended
                case .failed: return try await release(taskID)
                }
            }
            switch try await attempt(taskID, current, acknowledge: acknowledge) {
            case .end(let end):
                return end
            case .restart(let asked):
                acknowledge = acknowledge || asked
                restarts += 1
                if restarts > Self.maximumRestarts { return try await release(taskID) }
                briefing = nil
            }
        }
    }

    private func attempt(_ taskID: UUID, _ response: BriefingResponse, acknowledge: Bool) async throws -> Step {
        let api = context.api
        let resolution = WorkFolder.builder(
            reference: response.workReference, taskID: taskID, workRoot: context.workRoot, home: context.home)
        guard let folder = resolution.folder, let reference = resolution.reference else {
            context.log.warning("task \(taskID.contractString): its work reference is not a local folder")
            return .end(try await release(taskID))
        }
        let hash = response.briefing.hash
        if acknowledge, let step = try await check(context.command("acknowledge_task_briefing", {
            try await api.acknowledgeTaskBriefing(taskID: taskID, briefingHash: hash, key: $0)
        }), taskID) { return step }

        for item in Prompts.builderCriteria(of: response.briefing.contract.criteria)
        where item.criterion.state != .passed {
            let criterionID = item.criterion.id
            if let step = try await check(context.command("start_criterion", {
                try await api.startCriterion(taskID: taskID, criterionID: criterionID, key: $0)
            }), taskID) { return step }

            let prompt = Prompts.builder(
                number: item.number, criterion: item.criterion, briefing: response.briefing,
                reviewNotes: response.reviewNotes, folder: folder)
            let answer: ToolAnswer
            let driver = context.driver
            switch try await context.interruption.run(for: .task(taskID), {
                try await driver.execute(prompt: prompt, in: folder, purpose: .build)
            }) {
            case .answered(let answered):
                answer = answered
            case .failed(let failure):
                context.state.toolFailed()
                context.log.warning("task \(taskID.contractString), criterion \(item.number): \(failure)")
                return .end(try await release(taskID))
            case .accountStopped(let report):
                context.log.warning(
                    "task \(taskID.contractString), criterion \(item.number): the account stopped (\(report.kind.rawValue))")
                return .end(.accountStopped(report))
            }
            switch AnswerParser.builder(answer.text) {
            case .evidence(let value):
                context.state.toolAnswered()
                let evidence = AnswerParser.evidence(value)
                if let step = try await check(context.command("pass_criterion", {
                    try await api.passCriterion(taskID: taskID, criterionID: criterionID, evidence: evidence, key: $0)
                }), taskID) { return step }
            case .cannot:
                context.state.toolAnswered()
                context.log.info("task \(taskID.contractString), criterion \(item.number): the tool cannot do it")
                return .end(try await release(taskID))
            case .none:
                context.state.toolFailed()
                context.log.warning("task \(taskID.contractString), criterion \(item.number): no marker line")
                return .end(try await release(taskID))
            }
        }

        let submission = SubmitTaskRequest(handoffNote: Self.handoffNote, workReference: reference)
        if let step = try await check(context.command("submit_task", {
            try await api.submitTask(taskID: taskID, submission, key: $0)
        }), taskID) { return step }
        return .end(.finished)
    }

    /// Nil when the command completed; otherwise what the flow does next.
    private func check<Result>(_ sent: Sent<Result>, _ taskID: UUID) async throws -> Step? {
        switch sent {
        case .completed: return nil
        case .refused(let code): return try await answer(code, taskID)
        case .failed: return .end(try await release(taskID))
        }
    }

    private func answer(_ code: RefusalCode, _ taskID: UUID) async throws -> Step {
        switch RefusalAction(code) {
        case .restart: return .restart(acknowledge: RefusalAction.asksForAcknowledgement(code))
        case .pause: return .end(.paused)
        case .end: return .end(.ended)
        case .release: return .end(try await release(taskID))
        }
    }

    /// Gives the task back: `unable_to_continue`.
    private func release(_ taskID: UUID) async throws -> FlowEnd {
        let api = context.api
        _ = try await context.command("release_task") {
            try await api.releaseTask(taskID: taskID, reason: .unableToContinue, key: $0)
        }
        return .released
    }
}
