module Leverage
  # Records spend under the workspace lock, then applies the budget policy
  # to the updated amounts. Jobs count against the project only (AP-10).
  module Costs
    HOOK = "cost.reported".freeze

    # Gate uses the recorded event as its subject. The row's pre-transition
    # gate cannot supply it, because the event does not exist yet (DB-27).
    PolicyHook = Data.define(:event) do
      def hook = HOOK

      def gate_request_fields(_ctx)
        inputs = HookInputs.for(hook: HOOK, task: nil, params: { "event_id" => event.id })
        { task_id: event.task_id, project_id: event.project_id, round: event.round, subject_kind: "event",
          subject_id: event.id, inputs: inputs }
      end
    end
    private_constant :PolicyHook

    module_function

    def report(ctx, task:, subject:, tokens:, spend:)
      amount = BigDecimal(spend.to_s)
      task.update!(spent: task.spent + amount) if task && !subject.is_a?(Job)
      event = ctx.emit("cost.reported", task: task, subject: subject, payload: { tokens: tokens, spend: spend })
      project = Projects.add_spend(ctx, event.project_id, amount) if event.project_id

      result = Transitions::Gate.call(ctx, PolicyHook.new(event))
      result.evaluation.effects.each do |effect|
        check = result.checks.find { |row| row.rule_id == effect.rule_id }
        cause = ctx.events.reverse.find { |written| written.type == "check.finished" && written.subject_id == check&.id }
        case effect.effect
        when "project_paused"
          Projects.pause(ctx, project, by: :budget, cause: cause, rule_id: effect.rule_id) if project && !project.paused?
        when "task_held"
          hold_task(ctx, task, rule_id: effect.rule_id, cause: cause) if task && !subject.is_a?(Job)
        end
      end
      event
    end

    def cap_changed(ctx, task)
      return if task.budget_cap && task.budget_cap <= task.spent

      cause = ctx.events.reverse.find { |event| event.task_id == task.id && %w[task.changed task.contract_changed].include?(event.type) }
      Holds.open_holds(task).select { |hold| hold.reason == "budget" }.each do |hold|
        Holds.close(ctx, task: task, hold: hold, choice: "raise_cap", cause_id: cause&.id)
      end
    end

    def hold_task(ctx, task, rule_id:, cause:)
      return if Holds.ended?(ctx, task) || Holds.open_holds(task).any? { |hold| hold.reason == "budget" }

      Holds.open(ctx, task: task, reason: "budget", rule_id: rule_id, cause_id: cause&.id)
    end

    private_class_method :hold_task
  end
end
