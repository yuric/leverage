module Leverage
  module Transitions
    module Entries
      class StartAction < Entry
        def load(ctx)
          @seat = Seat.find_by(id: ctx.request.caller_id, workspace_id: ctx.workspace.id) ||
            raise(NotFound, "No such seat")
          @task = Task.find_by(id: ctx.request.params["id"], workspace_id: ctx.workspace.id) ||
            raise(NotFound, "No such task")
          @action = Action.find_by(id: ctx.request.params["aid"], task_id: @task.id, workspace_id: ctx.workspace.id) ||
            raise(NotFound, "No such action")
        end

        def refusals(_ctx)
          codes = Eligibility.task_refusals(@task, @seat)
          codes << state_refusal(@task.state)
          codes << "invalid_state" unless Actions.allows?(@action, command)
          codes << "on_hold" if Eligibility.on_hold?(@task)
          codes << { missing: "briefing_not_acknowledged", changed: "briefing_changed" }[
            Briefing.acknowledgement(@task, seat: @seat)]
          codes.compact
        end

        def perform(ctx)
          @task.update!(resume_pending_since: nil) if @task.resume_pending_since
          Actions.start(ctx, @action)
        end
      end
    end
  end
end
