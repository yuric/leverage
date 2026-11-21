module Leverage
  module Transitions
    module Entries
      class RequestAccess < Entry
        def load(ctx)
          @seat = Seat.find_by(id: ctx.request.caller_id, workspace_id: ctx.workspace.id) || raise(NotFound, "No such seat")
          @task = Task.find_by(id: ctx.request.params["id"], workspace_id: ctx.workspace.id) || raise(NotFound, "No such task")
        end

        def refusals(_ctx)
          return [ "forbidden" ] unless @seat.role == "builder"

          (Eligibility.task_refusals(@task, @seat) << state_refusal(@task.state)).compact
        end

        def perform(ctx)
          @task.update!(resume_pending_since: nil) if @task.resume_pending_since
          kind, id = ctx.actor
          hold = Holds.open(ctx, task: @task, reason: "access", actor_kind: kind, actor_id: id)
          hold.update!(detail: ctx.request.params.fetch("description"))
        end
      end
    end
  end
end
