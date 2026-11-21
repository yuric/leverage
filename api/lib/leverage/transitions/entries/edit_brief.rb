module Leverage
  module Transitions
    module Entries
      class EditBrief < Entry
        def load(ctx)
          @project = Project.find_by(id: ctx.request.params["id"], workspace_id: ctx.workspace.id) ||
            raise(NotFound, "No such project")
        end

        def perform(ctx)
          Projects.edit_brief(ctx, @project, entries: ctx.request.params.fetch("entries"))
        end
      end
    end
  end
end
