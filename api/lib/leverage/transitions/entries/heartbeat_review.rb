module Leverage
  module Transitions
    module Entries
      # heartbeat_review (PRD L120, L507): the reviewer holding the review
      # renews its lease (Leases.renew). No event; allowed under a hold. A
      # review lease past its due time has already been ended by its timer,
      # so the seat is refused lease_expired (EN-15).
      #
      # Result: HeartbeatResult, as Heartbeat gives it.
      #
      # Params: id (the review).
      class HeartbeatReview < Entry
        def load(ctx)
          @seat = Seat.find_by(id: ctx.request.caller_id, workspace_id: ctx.workspace.id) || raise(NotFound, "No such seat")
          @review = Review.find_by(id: ctx.request.params["id"], workspace_id: ctx.workspace.id) ||
            raise(NotFound, "No such review")
        end

        def refusals(_ctx)
          (Eligibility.review_refusals(@review, @seat) << state_refusal(nil)).compact
        end

        def perform(ctx)
          Leases.renew(ctx, @review)
          @result = { "lease_due_at" => Heartbeat.due_at(ctx, @review).utc.iso8601(6) }
        end
      end
    end
  end
end
