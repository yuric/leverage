module Leverage
  module Transitions
    module Entries
      # pass_review: Review passes, no outward action (PRD Lifecycle L92,
      # L510; milestone 2 plan EN-9, EN-12). At task.before_done the review
      # gets its verdict, notes and lease's end (it keeps its reviewer,
      # DB-20), the review criterion is passed by the reviewer, and the task
      # is Done with no holder; it keeps its builder seat. review.passed and
      # task.done are written, then cost.reported about the review with the
      # verdict's tokens and spend, which add to the task's spent; no policy
      # runs (EN-12). A work call, blocked by a hold (L174). The row with an
      # outward action cannot be reached: no contract has one (SC-3).
      #
      # 422 invalid when a pass names failed criteria.
      #
      # Params: id (the review), verdict "passed", failed_criteria [], notes,
      # tokens, spend.
      class PassReview < Entry
        def load(ctx)
          @params = ctx.request.params
          @seat = Seat.find_by(id: ctx.request.caller_id, workspace_id: ctx.workspace.id) || raise(NotFound, "No such seat")
          @review = Review.find_by(id: @params["id"], workspace_id: ctx.workspace.id) || raise(NotFound, "No such review")
          @task = Task.find_by!(id: @review.task_id, workspace_id: ctx.workspace.id)
          raise Invalid, "A pass names no failed criteria." if Array(@params["failed_criteria"]).any?
        end

        def refusals(_ctx)
          codes = Eligibility.review_refusals(@review, @seat)
          codes << state_refusal(@task.state, [ "no_outward_action" ])
          codes << "on_hold" if Eligibility.on_hold?(@task)
          codes << { missing: "briefing_not_acknowledged", changed: "briefing_changed" }[
            Briefing.acknowledgement(@task, seat: @seat, review: @review)]
          codes.compact
        end

        def gate_request_fields(_ctx)
          super.merge(task_id: @task.id, project_id: @task.project_id, round: @task.round, subject_kind: "review",
            subject_id: @review.id)
        end

        def perform(ctx)
          Leases.end_lease(ctx, @review)
          @review.update!(verdict: "passed", failed_criteria: [], notes: @params["notes"])
          Criterion.where(task_id: @task.id, kind: "review", removed_at: nil).find_each do |criterion|
            criterion.update!(state: "passed", passed_at: ctx.at, passed_by_seat_id: @seat.id)
          end
          spend = BigDecimal(@params.fetch("spend", 0).to_s)
          @task.update!(state: "done", holder_seat_id: nil, spent: @task.spent + spend)
          ctx.emit("review.passed", task: @task, subject: @review, payload: {})
          ctx.emit("task.done", task: @task, payload: {})
          ctx.emit("cost.reported", task: @task, subject: @review,
            payload: { tokens: @params.fetch("tokens", 0), spend: @params.fetch("spend", 0) })
          @result = nil
        end
      end
    end
  end
end
