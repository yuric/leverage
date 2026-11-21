module Leverage
  module Transitions
    module Entries
      # revert_rule (PRD L342; milestone 4 plan RD-5, RD-7; DB-29): the
      # owner reverts a shipped rule to its default: the shipped fields as
      # its next version (rule.reverted). A custom rule has no default:
      # invalid_state (RD-5).
      #
      # Params: id (the rule).
      class RevertRule < Entry
        def load(ctx)
          @rule = Rule.find_by(id: ctx.request.params["id"], workspace_id: ctx.workspace.id) || raise(NotFound, "No such rule")
        end

        def refusals(_ctx)
          causes = [ state_refusal(nil) ]
          shipped = Rules::Shipped.all.any? { |record| record.key == @rule.key }
          causes << Refusal.new(code: Contract.state_machine.fetch("unlisted_pair_refusal")) if @rule.removed_at || !shipped
          causes.compact
        end

        def perform(ctx)
          RuleRecords.revert(ctx, @rule)
          @result = nil
        end
      end
    end
  end
end
