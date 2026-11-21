module Leverage
  module JobInputs
    # The task and its project brief for a planner (RD-37).
    module ContractDraft
      module_function

      def call(job, task)
        project = task.project_id && Project.find_by(id: task.project_id, workspace_id: job.workspace_id)
        {
          "task_id" => task.id, "project_id" => task.project_id, "brief_version" => project&.brief_version || 0,
          "material" => {
            "role_file" => RoleFiles.text("planner"), "title" => task.title.to_s, "goal" => task.goal.to_s,
            "details" => task.details,
            "criteria" => JobInputs.live_criteria(task).map { |criterion| { "text" => criterion.text.to_s, "kind" => criterion.kind } },
            "work_reference" => task.work_reference, "minimum_strength_rank" => task.minimum_strength_rank,
            "budget_cap" => task.budget_cap&.to_f, "brief" => brief(project)
          }
        }
      end

      # The project's brief entries (BriefEntry); none for a task with no
      # project, and none is written in this milestone.
      def brief(project)
        return [] unless project

        BriefEntry.where(project_id: project.id, workspace_id: project.workspace_id).order(:created_at, :id).map do |entry|
          { "id" => entry.id, "project_id" => entry.project_id, "kind" => entry.kind, "text" => entry.text.to_s,
            "author_kind" => entry.author_kind, "author_id" => entry.author_id }
        end
      end

      private_class_method :brief
    end
  end
end
