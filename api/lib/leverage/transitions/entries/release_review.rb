module Leverage
  module Transitions
    module Entries
      # release_review (PRD Lifecycle L90, L507): the reviewer gives the
      # review back. The review has no reviewer and no lease, the task stays
      # In review, unassigned, and any reviewer may claim it, this one
      # included. review.released is about the review. Allowed under a hold.
      # The reviewer's pending pass, if it has one, is cancelled first with
      # invalid_state (milestone 4 plan §2.1 rule 11).
      #
      # Params: id (the review).
      class ReleaseReview < Entry
        def load(ctx)
          @seat = Seat.find_by(id: ctx.request.caller_id, workspace_id: ctx.workspace.id) || raise(NotFound, "No such seat")
          @review = Review.find_by(id: ctx.request.params["id"], workspace_id: ctx.workspace.id) ||
            raise(NotFound, "No such review")
          @task = Task.find_by!(id: @review.task_id, workspace_id: ctx.workspace.id)
        end

        def refusals(_ctx)
          (Eligibility.review_refusals(@review, @seat) << state_refusal(@task.state)).compact
        end

        def perform(ctx)
          pending = PendingTransitions.of(@task)
          PendingTransitions.cancel(ctx, pending, "invalid_state") if pending
          Leases.end_lease(ctx, @review)
          @review.update!(reviewer_seat_id: nil, credential_id: nil)
          ctx.emit("review.released", task: @task, subject: @review, payload: {})
          @result = nil
        end
      end
    end
  end
end
