module Leverage
  # A settled check re-enters its pending transition or its action (AE-3).
  module CheckReentry
    module_function

    def after(ctx, rule_check, trigger)
      if rule_check.pending_transition_id
        pending = PendingTransition.find_by(id: rule_check.pending_transition_id, workspace_id: ctx.workspace.id,
          state: PendingTransitions::PENDING)
        PendingTransitions.reenter(ctx, pending, trigger) if pending
      elsif rule_check.subject_kind == "action"
        action = Action.find_by!(id: rule_check.subject_id, workspace_id: ctx.workspace.id, task_id: rule_check.task_id)
        Finishing.reenter_action(ctx, action, trigger)
      end
    end
  end
end
