module Leverage
  # The round limit and escalation count failed verdicts, including a
  # before-done gate failure. Rework requested by the owner has no verdict.
  module ReviewRounds
    module_function

    def failed_count(task)
      Review.where(workspace_id: task.workspace_id, task_id: task.id, verdict: "failed").count
    end
  end
end
