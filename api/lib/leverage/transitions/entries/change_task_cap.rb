module Leverage
  module Transitions
    module Entries
      class ChangeTaskCap < Entry
        def load(ctx)
          @task = Task.find_by(id: ctx.request.params["id"], workspace_id: ctx.workspace.id) ||
            raise(NotFound, "No such task")
        end

        def perform(ctx)
          Projects.change_task(ctx, @task, budget_cap: ctx.request.params.fetch("budget_cap"))
          Costs.cap_changed(ctx, @task)
        end
      end
    end
  end
end
