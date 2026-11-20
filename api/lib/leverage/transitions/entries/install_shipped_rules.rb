module Leverage
  module Transitions
    module Entries
      # install_shipped_rules (PRD L434 with Q-12; milestone 4 plan RD-1 to
      # RD-3, S-1): the app writes the seven shipped rules of a workspace
      # that has none, each with rule.created, as the app with no key. bin/
      # rails leverage:install_shipped_rules applies it through
      # Timers.apply_workspace before the server starts. A workspace that
      # has any rule is refused invalid_state and gets nothing, so a second
      # start, or two at once, write the rules once. It counts as turning
      # the rules on (RD-3): briefings change with them, and "No reviewer is
      # eligible" is re-evaluated after it (ReviewerEligibility.after_command).
      class InstallShippedRules < Entry
        def refusals(ctx)
          causes = [ state_refusal(nil) ]
          if Rule.exists?(workspace_id: ctx.workspace.id)
            causes << Refusal.new(code: Contract.state_machine.fetch("unlisted_pair_refusal"))
          end
          causes.compact
        end

        def perform(ctx)
          RuleRecords.install_shipped(ctx)
          @result = nil
        end
      end
    end
  end
end
