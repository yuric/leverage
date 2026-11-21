module Leverage
  module Transitions
    module Entries
      class StopAction < Entry
        def load(ctx)
          @action = Action.find_by(id: ctx.request.params["id"], workspace_id: ctx.workspace.id) ||
            raise(NotFound, "No such action")
          @task = Task.find(@action.task_id)
        end

        def refusals(ctx)
          asked = ctx.request.caller_kind == "owner" ||
            (@action.state == "requested" && Actions.approval_job_check(ctx, @action)&.effect == "stopped")
          allowed = asked && Actions.allows?(@action, command)
          [ state_refusal(@task.state), ("invalid_state" unless allowed) ].compact
        end

        def perform(ctx)
          Actions.stop(ctx, @action, by: ctx.actor)
        end
      end
    end
  end
end
