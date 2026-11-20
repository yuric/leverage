module Leverage
  module Transitions
    module Entries
      # enable_rule (PRD L379; milestone 4 plan RD-3, RD-5): the owner turns
      # a rule on (rule.enabled). A request already made is not touched. A
      # rule that is on already, or removed, is invalid_state: nothing would
      # change (milestone 4 WP8's choice, in its notes).
      #
      # Params: id (the rule).
      class EnableRule < Entry
        def load(ctx)
          @rule = Rule.find_by(id: ctx.request.params["id"], workspace_id: ctx.workspace.id) || raise(NotFound, "No such rule")
        end

        def refusals(_ctx)
          causes = [ state_refusal(nil) ]
          causes << Refusal.new(code: Contract.state_machine.fetch("unlisted_pair_refusal")) if @rule.removed_at || @rule.enabled
          causes.compact
        end

        def perform(ctx)
          RuleRecords.enable(ctx, @rule)
          @result = nil
        end
      end
    end
  end
end
