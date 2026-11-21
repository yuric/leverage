module Leverage
  module Transitions
    module Entries
      # The two owner routes pass their path id as task_id or project_id.
      class DeleteContent < Entry
        def load(ctx)
          task_id, project_id = ctx.request.params.values_at("task_id", "project_id")
          raise Invalid, "Name exactly one task or project." if task_id.present? == project_id.present?

          workspace_id = ctx.workspace.id
          if task_id.present?
            @task = Task.find_by(id: task_id, workspace_id: workspace_id) || raise(NotFound, "No such task")
          else
            @project = Project.find_by(id: project_id, workspace_id: workspace_id) || raise(NotFound, "No such project")
          end
        end

        def refusals(_ctx)
          guard = ContentDeletion.deletable?(task: @task, project: @project) ? :content_deletable : :content_not_deletable
          [ state_refusal(nil, [ guard ]) ].compact
        end

        def perform(ctx)
          ContentDeletion.delete(ctx, task: @task, project: @project)
        end
      end
    end
  end
end
