module Leverage
  module Transitions
    module Entries
      # acknowledge_review_briefing (PRD Lifecycle L85, L475; DB-11): the
      # reviewer holding the review acknowledges the reviewer's briefing
      # hash under its review lease (the review's review.started). The row
      # names the review, and so does task.briefing_acknowledged, as its
      # subject. Not a work call.
      #
      # Refusals: the reviewer's (lease_expired, task_cancelled, not_holder,
      # forbidden), invalid_state, and briefing_changed for a hash that is
      # not the current one.
      #
      # Params: id (the review), briefing_hash.
      class AcknowledgeReviewBriefing < Entry
        def load(ctx)
          @seat = Seat.find_by(id: ctx.request.caller_id, workspace_id: ctx.workspace.id) || raise(NotFound, "No such seat")
          @review = Review.find_by(id: ctx.request.params["id"], workspace_id: ctx.workspace.id) ||
            raise(NotFound, "No such review")
          @task = Task.find_by!(id: @review.task_id, workspace_id: ctx.workspace.id)
          @hash = ctx.request.params["briefing_hash"].to_s
        end

        def refusals(_ctx)
          codes = Eligibility.review_refusals(@review, @seat)
          codes << state_refusal(@task.state)
          codes << "briefing_changed" unless @hash == Briefing.hash_for(@task, seat: @seat, review: @review)
          codes.compact
        end

        def perform(ctx)
          lease = Briefing.lease_event(@task, seat: @seat, review: @review)
          BriefingAcknowledgement.find_or_create_by!(workspace_id: @task.workspace_id, seat_id: @seat.id,
            task_id: @task.id, review_id: @review.id, lease_event_id: lease.id, briefing_hash: @hash) do |row|
            row.acknowledged_at = ctx.at
          end
          ctx.emit("task.briefing_acknowledged", task: @task, subject: @review, payload: {})
          @result = nil
        end
      end
    end
  end
end
