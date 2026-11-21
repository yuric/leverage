module Leverage
  # Records spend under the workspace lock. Reviews and seats' own reports
  # count against the task and its project. Jobs count against the project
  # only (AP-10). A seat's own report has no event subject.
  module Costs
    module_function

    def report(ctx, task:, subject:, tokens:, spend:)
      amount = BigDecimal(spend.to_s)
      task.update!(spent: task.spent + amount) if task && !subject.is_a?(Job)
      event = ctx.emit("cost.reported", task: task, subject: subject, payload: { tokens: tokens, spend: spend })
      if event.project_id
        project = Project.find_by!(id: event.project_id, workspace_id: ctx.workspace.id)
        project.update!(spent: project.spent + amount)
      end
      event
    end

    def cap_changed(_ctx, _task) = nil
  end
end
