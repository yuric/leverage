module Leverage
  module Transitions
    module Entries
      class ChangeTaskProject < Entry
        def load(ctx)
          params = ctx.request.params
          @task = Task.find_by(id: params["id"], workspace_id: ctx.workspace.id) || raise(NotFound, "No such task")
          @projects = Project.where(workspace_id: ctx.workspace.id)
          project_id = params.fetch("project_id")
          @project = project_id && (@projects.find_by(id: project_id) || raise(Invalid, "No such project in this workspace."))
        end

        def perform(ctx)
          source = @task.project_id && @projects.find(@task.project_id)
          changed = Projects.change_task(ctx, @task, project_id: @project&.id)
          return if @project&.id == source&.id

          # A move between paused projects keeps the clock paused and
          # prevents the source hold from re-entering a waiting transition.
          Projects.hold_if_paused(ctx, @task, cause: changed)
          Projects.release_from(ctx, @task, source, cause: changed)
        end
      end
    end
  end
end
