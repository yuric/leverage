module Leverage
  module Transitions
    module Entries
      # start_criterion (PRD Lifecycle L86, L496): optional; the builder
      # announces the builder criterion it works on. criterion.started is
      # written about the criterion, whose state becomes started; a criterion
      # that had passed loses its pass and must be passed again (the state
      # follows the event, so replay agrees). A work call: the briefing must
      # be acknowledged (L473). Not blocked by a hold (state_machine.json).
      # It clears a pending resume.
      #
      # 404 for a criterion of another task; 422 invalid for the review
      # criterion, which only a verdict passes.
      #
      # Params: id (the task), cid (the criterion).
      class StartCriterion < Entry
        def load(ctx)
          @seat = Seat.find_by(id: ctx.request.caller_id, workspace_id: ctx.workspace.id) || raise(NotFound, "No such seat")
          @task = Task.find_by(id: ctx.request.params["id"], workspace_id: ctx.workspace.id) || raise(NotFound, "No such task")
          @criterion = Criterion.find_by(id: ctx.request.params["cid"], task_id: @task.id, removed_at: nil) ||
            raise(NotFound, "No such criterion")
          raise Invalid, "Only a verdict passes the review criterion." unless @criterion.kind == "build"
        end

        def refusals(_ctx)
          codes = Eligibility.task_refusals(@task, @seat)
          codes << state_refusal(@task.state)
          codes << briefing_refusal
          codes.compact
        end

        def perform(ctx)
          @criterion.update!(state: "started", passed_at: nil, passed_by_seat_id: nil)
          @task.update!(resume_pending_since: nil) if @task.resume_pending_since
          ctx.emit("criterion.started", task: @task, subject: @criterion, payload: {})
          @result = nil
        end

        private

        def briefing_refusal
          { missing: "briefing_not_acknowledged", changed: "briefing_changed" }[Briefing.acknowledgement(@task, seat: @seat)]
        end
      end
    end
  end
end
