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
          if @action.state == "requested" && ctx.request.caller_kind == "seat"
            @approval_check = Actions.approval_job_check(ctx, @action)
          end
          asked = ctx.request.caller_kind == "owner" || @approval_check&.effect == "stopped"
          allowed = asked && Actions.allows?(@action, command)
          [ state_refusal(@task.state), ("invalid_state" unless allowed) ].compact
        end

        def perform(ctx)
          Actions.stop(ctx, @action, by: ctx.actor, approval_job_id: (ctx.request.params["job_id"] if @approval_check))
        end
      end
    end
  end
end
