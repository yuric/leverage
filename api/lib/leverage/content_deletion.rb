module Leverage
  # Blanks the content columns while preserving the rows and their timing
  # (DB-42, milestone 5 plan AP-36).
  module ContentDeletion
    TERMINAL_STATES = %w[done cancelled].freeze
    TASK_COLUMNS = { title: nil, goal: nil, details: nil, work_reference: nil }.freeze
    RELATED_COLUMNS = {
      Review => %i[handoff_note notes],
      Criterion => %i[text],
      Question => %i[text assumption answer],
      Action => %i[description],
      Hold => %i[detail],
      RuleCheck => %i[reason override_reason],
      Job => %i[input result],
      PendingTransition => %i[params]
    }.freeze

    module_function

    def deletable?(task: nil, project: nil)
      return false if (task || project).content_deleted_at
      return TERMINAL_STATES.include?(task.state) if task

      !tasks_in(project).where.not(state: TERMINAL_STATES).exists?
    end

    def delete(ctx, task: nil, project: nil)
      if project
        project.update_columns(name: nil, goal: nil, content_deleted_at: ctx.at)
        BriefEntry.where(workspace_id: project.workspace_id, project_id: project.id).update_all(text: nil)
        Idempotency.forget_project_claims(project)
        ctx.emit("content.deleted", project_id: project.id)
        tasks_in(project).where(content_deleted_at: nil).find_each { |member| delete_task(ctx, member) }
      else
        delete_task(ctx, task)
      end
    end

    def tasks_in(project)
      Task.where(workspace_id: project.workspace_id, project_id: project.id)
    end

    def delete_task(ctx, task)
      scope = { workspace_id: task.workspace_id, task_id: task.id }
      criteria = Criterion.where(scope).select(:id)
      Evidence.where(workspace_id: task.workspace_id, criterion_id: criteria).update_all(value: nil)
      Idempotency.forget_task_refusals(task)
      RELATED_COLUMNS.each do |model, columns|
        model.where(scope).update_all(columns.index_with(nil))
      end
      Idempotency.forget_task_claims(task)
      task.update_columns(**TASK_COLUMNS, content_deleted_at: ctx.at)
      ctx.emit("content.deleted", task: task)
    end

    private_class_method :tasks_in, :delete_task
  end
end
