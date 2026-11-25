import Foundation
import LeverageKit

/// A reviewer's work on one review: claim it, acknowledge its briefing,
/// drive the tool once, read-only, in the work folder, and give the
/// verdict: passed, or failed naming the builder criteria the tool failed,
/// with the tool's tokens and spend 0 for a login (CL-6, CL-11). A pass that
/// answers `pending` (a model check at "when the review has passed",
/// milestone 4) is waited on by its key, with the heartbeat running; once it
/// is decided, a pass or a failed review alike, the flow ends.
struct ReviewerFlow: Sendable {
    let context: FlowContext
    /// General can run on Gemini, which cannot drive the review prompt (GA-9).
    let canRunReview: Bool

    /// Claims the next review and does it; nil when nothing was claimed.
    func claim() async throws -> FlowEnd? {
        guard canRunReview else { return nil }
        let api = context.api
        guard case .completed(let claim?) = try await context.command("claim_next_review", {
            try await api.claimNextReview(key: $0)
        }) else { return nil }
        context.log.info("claimed review \(claim.review.id.contractString)")
        let start = BriefingResponse(briefing: claim.briefing, workReference: claim.workReference)
        return try await work(claim.review.id, start: start, leaseDue: claim.lease.leaseDueAt)
    }

    /// Goes on with a review this seat holds, from its briefing: on
    /// `briefing_changed` acknowledging it first, and at the start of a run
    /// that continues the review only when asked (HD-9).
    func continueReview(_ reviewID: UUID, acknowledgement: Acknowledgement = .always) async throws -> FlowEnd {
        try await work(reviewID, start: nil, leaseDue: nil, acknowledgement: acknowledgement)
    }

    private func work(
        _ reviewID: UUID, start: BriefingResponse?, leaseDue: Date?, acknowledgement: Acknowledgement = .always
    ) async throws -> FlowEnd {
        context.state.hold(.review(reviewID))
        let end: FlowEnd
        if canRunReview {
            end = try await Heartbeat.around(.review(reviewID), leaseDue: leaseDue, context: context) {
                try await steps(reviewID, start: start, acknowledgement: acknowledgement)
            }
        } else {
            end = try await release(reviewID)
        }
        if end != .paused { context.state.hold(.nothing) }
        if case .accountStopped(let report) = end { context.state.accountStopped(report) }
        context.state.flowEnded(end, of: .review(reviewID))
        context.log.info("review \(reviewID.contractString): \(end.name)")
        return end
    }

    private enum Step {
        case end(FlowEnd)
        /// Read the briefing again; `acknowledge` when the refusal asked for
        /// an acknowledgement.
        case restart(acknowledge: Bool)
    }

    private func steps(_ reviewID: UUID, start: BriefingResponse?, acknowledgement: Acknowledgement) async throws
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
                switch try await context.read("get_review_briefing", {
                    try await api.reviewBriefing(reviewID: reviewID)
                }) {
                case .value(let read): current = read
                case .refused(let code):
                    switch try await answer(code, reviewID) {
                    case .end(let end): return end
                    case .restart(let asked):
                        acknowledge = acknowledge || asked
                        restarts += 1
                        if restarts > BuilderFlow.maximumRestarts { return try await release(reviewID) }
                        try await Task.sleep(for: context.timing.errorPause)
                        continue
                    }
                case .gone: return .ended
                case .failed: return try await release(reviewID)
                }
            }
            switch try await attempt(reviewID, current, acknowledge: acknowledge) {
            case .end(let end):
                return end
            case .restart(let asked):
                acknowledge = acknowledge || asked
                restarts += 1
                if restarts > BuilderFlow.maximumRestarts { return try await release(reviewID) }
                briefing = nil
            }
        }
    }

    private func attempt(_ reviewID: UUID, _ response: BriefingResponse, acknowledge: Bool) async throws -> Step {
        let api = context.api
        guard let folder = WorkFolder.reviewer(reference: response.workReference, home: context.home) else {
            context.log.warning("review \(reviewID.contractString): its work reference is not a local folder")
            return .end(try await release(reviewID))
        }
        let hash = response.briefing.hash
        if acknowledge, let step = try await check(context.command("acknowledge_review_briefing", {
            try await api.acknowledgeReviewBriefing(reviewID: reviewID, briefingHash: hash, key: $0)
        }), reviewID) { return step }

        let numbered = Prompts.builderCriteria(of: response.briefing.contract.criteria)
        let prompt = Prompts.reviewer(briefing: response.briefing)
        let answer: ToolAnswer
        let driver = context.driver
        switch try await context.interruption.run(for: .review(reviewID), {
            try await driver.execute(prompt: prompt, in: folder, purpose: .review)
        }) {
        case .answered(let answered):
            answer = answered
        case .failed(let failure):
            context.state.toolFailed()
            context.log.warning("review \(reviewID.contractString): \(failure)")
            return .end(try await release(reviewID))
        case .accountStopped(let report):
            context.log.warning("review \(reviewID.contractString): the account stopped (\(report.kind.rawValue))")
            return .end(.accountStopped(report))
        }
        guard let review = AnswerParser.reviewer(answer.text, expecting: numbered.map(\.number)) else {
            context.state.toolFailed()
            context.log.warning("review \(reviewID.contractString): no verdict for every criterion")
            return .end(try await release(reviewID))
        }
        context.state.toolAnswered()

        let failed = numbered.filter { review.failed.contains($0.number) }
        let notes = review.notes ?? (failed.isEmpty
            ? "Every criterion holds."
            : "Criterion \(failed.map { String($0.number) }.joined(separator: ", ")) does not hold.")
        let verdict = GiveVerdictRequest(
            verdict: failed.isEmpty ? .passed : .failed, failedCriteria: failed.map(\.criterion.id), notes: notes,
            tokens: answer.tokens, spend: 0)
        if let step = try await check(context.command("give_verdict", {
            try await api.giveVerdict(reviewID: reviewID, verdict, key: $0)
        }), reviewID) { return step }
        return .end(.finished)
    }

    private func check<Result>(_ sent: Sent<Result>, _ reviewID: UUID) async throws -> Step? {
        switch sent {
        case .completed: return nil
        case .refused(let code): return try await answer(code, reviewID)
        case .failed: return .end(try await release(reviewID))
        }
    }

    private func answer(_ code: RefusalCode, _ reviewID: UUID) async throws -> Step {
        switch RefusalAction(code) {
        case .restart: return .restart(acknowledge: RefusalAction.asksForAcknowledgement(code))
        case .pause: return .end(.paused)
        case .end: return .end(.ended)
        case .release: return .end(try await release(reviewID))
        }
    }

    /// Gives the review back (release review).
    private func release(_ reviewID: UUID) async throws -> FlowEnd {
        let api = context.api
        _ = try await context.command("release_review") { try await api.releaseReview(reviewID: reviewID, key: $0) }
        return .released
    }
}
