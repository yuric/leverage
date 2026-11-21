module Leverage
  module Transitions
    module Entries
      # disable_rule (PRD L162, L166, L167, L379, L973; milestone 4 plan
      # RD-45, S-5): the owner turns a rule off (rule.disabled). Its checks
      # in flight are withdrawn with their jobs, its check_error,
      # claim_gate_failed and rerun_limit holds close with their items, and
      # each command that waited on it is gated again, so it completes if
      # nothing else blocks (RuleRecords.disable). A rule that is off
      # already, or removed, is invalid_state (milestone 4 WP8's choice, in
      # its notes).
      #
      # Params: id (the rule).
      class DisableRule < Entry
        def load(ctx)
          @rule = Rule.find_by(id: ctx.request.params["id"], workspace_id: ctx.workspace.id) || raise(NotFound, "No such rule")
        end

        def refusals(_ctx)
          causes = [ state_refusal(nil) ]
          causes << Refusal.new(code: Contract.state_machine.fetch("unlisted_pair_refusal")) if @rule.removed_at || !@rule.enabled
          causes.compact
        end

        def perform(ctx)
          RuleRecords.disable(ctx, @rule)
          @result = nil
        end
      end
    end
  end
end
