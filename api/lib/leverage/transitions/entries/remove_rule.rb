module Leverage
  module Transitions
    module Entries
      # remove_rule (PRD L342, L379; milestone 4 plan RD-5, RD-45; DB-29):
      # the owner removes a custom rule (rule.removed); what it has in
      # flight is withdrawn as when it is turned off (RuleRecords.remove). A
      # shipped rule is turned off, never removed, and a removed rule
      # cannot be removed again: invalid_state (RD-5).
      #
      # Params: id (the rule).
      class RemoveRule < Entry
        def load(ctx)
          @rule = Rule.find_by(id: ctx.request.params["id"], workspace_id: ctx.workspace.id) || raise(NotFound, "No such rule")
        end

        def refusals(_ctx)
          causes = [ state_refusal(nil) ]
          shipped = Rules::Shipped.all.any? { |record| record.key == @rule.key }
          causes << Refusal.new(code: Contract.state_machine.fetch("unlisted_pair_refusal")) if @rule.removed_at || shipped
          causes.compact
        end

        def perform(ctx)
          RuleRecords.remove(ctx, @rule)
          @result = nil
        end
      end
    end
  end
end
