module Leverage
  module Rules
    module Checkers
      # Evaluates the spending already recorded for this report (AP-10).
      module PauseProjectAtBudget
        module_function

        def call(version:, request:, task:)
          event = Event.find_by(workspace_id: request.workspace_id, id: request.inputs.fetch("event_id"),
            type: "cost.reported", task_id: request.task_id)
          effects = []
          if event&.project_id && projects_at_budget(request.workspace_id).exists?(id: event.project_id, paused: false)
            effects << "project_paused"
          end
          effects << "task_held" if event && hold_task?(task, event)

          AppCheckers::Result.new(result: "applied", reason: nil, effect: effects)
        end

        def projects_at_budget(workspace_id)
          Project.where(workspace_id: workspace_id).where("spent >= budget")
        end

        def hold_task?(task, event)
          return false unless task && [ nil, "review" ].include?(event.subject_kind)
          return false if %w[done cancelled].include?(task.state) || task.budget_cap.nil? || task.spent < task.budget_cap

          !Hold.exists?(workspace_id: task.workspace_id, task_id: task.id, reason: "budget", closed_at: nil)
        end

        private_class_method :hold_task?
      end
    end
  end
end
