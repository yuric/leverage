module Leverage
  module Transitions
    module Entries
      class ReportActionDone < Entry
        def load(ctx)
          @seat = Seat.find_by(id: ctx.request.caller_id, workspace_id: ctx.workspace.id) ||
            raise(NotFound, "No such seat")
          @task = Task.find_by(id: ctx.request.params["id"], workspace_id: ctx.workspace.id) ||
            raise(NotFound, "No such task")
          @action = Action.find_by(id: ctx.request.params["aid"], task_id: @task.id, workspace_id: ctx.workspace.id) ||
            raise(NotFound, "No such action")
        end

        def refusals(_ctx)
          @last = Actions.last_open?(@action)
          refusal = state_refusal(@task.state, [ @last ? "last_open_action" : "not_last_open_action" ])
          return [ refusal ] if refusal

          codes = Eligibility.task_refusals(@task, @seat)
          codes << "invalid_state" unless Actions.allows?(@action, command)
          codes << "on_hold" if Eligibility.on_hold?(@task)
          codes << { missing: "briefing_not_acknowledged", changed: "briefing_changed" }[
            Briefing.acknowledgement(@task, seat: @seat)]
          codes.compact
        end

        def perform(ctx)
          @task.update!(resume_pending_since: nil) if @task.resume_pending_since
          Actions.report_done(ctx, @action)
          return unless @last

          Leases.end_lease(ctx, @task)
          @task.update!(state: "done", holder_seat_id: nil)
          ctx.emit("task.done", task: @task, payload: {})
        end
      end
    end
  end
end
