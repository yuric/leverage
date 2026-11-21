module Leverage
  module Transitions
    module Entries
      class ChangeTaskPriority < Entry
        def load(ctx)
          @task = Task.find_by(id: ctx.request.params["id"], workspace_id: ctx.workspace.id) ||
            raise(NotFound, "No such task")
        end

        def perform(ctx)
          Projects.change_task(ctx, @task, priority: ctx.request.params.fetch("priority"))
        end
      end
    end
  end
end
