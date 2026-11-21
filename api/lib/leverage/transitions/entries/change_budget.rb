module Leverage
  module Transitions
    module Entries
      class ChangeBudget < Entry
        def load(ctx)
          @project = Project.find_by(id: ctx.request.params["id"], workspace_id: ctx.workspace.id) ||
            raise(NotFound, "No such project")
        end

        def perform(ctx)
          Projects.change_budget(ctx, @project, budget: ctx.request.params.fetch("budget"))
        end
      end
    end
  end
end
