module V1
  module Agent
    # The review calls: claim, heartbeat, release, briefing, acknowledge and
    # the verdict (milestone 2 plan §2.1). The briefing is a read.
    class ReviewsController < BaseController
      def claim_next = run("claim_next_review", "claim_review")
      def heartbeat = run("heartbeat_review", "heartbeat_review", ids: [ :id ])
      def release = run("release_review", "release_review", ids: [ :id ])
      def acknowledge_briefing = run("acknowledge_review_briefing", "acknowledge_review_briefing", ids: [ :id ])

      # A verdict is one operation and two commands: it passes the work or
      # fails it (registry: pass_review, fail_review).
      def verdict
        run("give_verdict", ->(body) { body.fetch("verdict") == "passed" ? "pass_review" : "fail_review" }, ids: [ :id ])
      end

      # GET /v1/reviews/{id}/briefing: the reviewer's briefing and the work
      # reference of the review this seat holds, and no notes. Another seat's
      # review, one with a verdict and one past its lease are 404.
      def briefing
        review = Review.where(id: uuid_param!(:id), workspace_id: current_seat.workspace_id, reviewer_seat_id: current_seat.id,
          verdict: nil).where(Leverage::Reads::NextItem::LIVE).take || raise(NotFound, "No such review")
        render json: { briefing: Leverage::Briefing.build(review, current_seat), work_reference: Task.find(review.task_id).work_reference,
                       review_notes: [] }
      end
    end
  end
end
