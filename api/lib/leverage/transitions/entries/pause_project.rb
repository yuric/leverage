module Leverage
  module Transitions
    module Entries
      class PauseProject < Entry
        def load(ctx)
          @project = Project.find_by(id: ctx.request.params["id"], workspace_id: ctx.workspace.id) ||
            raise(NotFound, "No such project")
        end

        def perform(ctx)
          Projects.pause(ctx, @project, by: :owner)
        end
      end
    end
  end
end
