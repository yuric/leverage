module Leverage
  module Transitions
    module Entries
      # Write the shipped rules at startup (UI-5). An empty workspace gets
      # rule.created for each shipped rule. Otherwise only rules still on
      # a superseded default get rule.reverted. Both use the app with no
      # key and take the workspace lock before deciding what to write.
      class InstallShippedRules < Entry
        def load(ctx)
          @install = !Rule.exists?(workspace_id: ctx.workspace.id)
          @superseded = RuleRecords.superseded_shipped_rules(ctx.workspace.id) unless @install
        end

        def refusals(_ctx)
          causes = [ state_refusal(nil) ]
          if !@install && @superseded.empty?
            causes << Refusal.new(code: Contract.state_machine.fetch("unlisted_pair_refusal"))
          end
          causes.compact
        end

        def perform(ctx)
          if @install
            RuleRecords.install_shipped(ctx)
          else
            @superseded.each { |rule| RuleRecords.revert(ctx, rule) }
          end
          @result = nil
        end
      end
    end
  end
end
