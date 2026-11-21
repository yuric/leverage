module Leverage
  module Transitions
    module Entries
      class RequestAction < Entry
        def load(ctx)
          @action = Action.find_by(id: ctx.request.params["id"], workspace_id: ctx.workspace.id) ||
            raise(NotFound, "No such action")
          @task = Task.find(@action.task_id)
        end

        def refusals(ctx)
          return [ "forbidden" ] unless ctx.request.by_app?

          [ state_refusal(@task.state), ("invalid_state" unless @action.state == "requested") ].compact
        end

        # This hook plans checks for an action already requested by the
        # passing review. The gate handles it directly.
        def hook = nil

        def perform(ctx)
          Gate.request_action(ctx, @action)
        end
      end
    end
  end
end
