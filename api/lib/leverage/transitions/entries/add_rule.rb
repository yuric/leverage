module Leverage
  module Transitions
    module Entries
      # add_rule (PRD L342, L423, L464; milestone 4 plan RD-4, RD-21 to
      # RD-24): the owner adds a custom rule, a model-checked gate that
      # blocks, at one of the five moments, with rule.created. Its moment
      # is fixed when it is added (RD-4). Invalid fields are refused during
      # load before anything is written.
      #
      # Params: name, instruction, hook, scope (AddRuleRequest).
      class AddRule < Entry
        FIELDS = %w[name instruction hook scope].freeze

        def load(ctx)
          @fields = ctx.request.params.slice(*FIELDS)
          RuleRecords.added_version(@fields, workspace_id: ctx.workspace.id)
        end

        def refusals(_ctx) = [ state_refusal(nil) ].compact

        def perform(ctx)
          RuleRecords.add(ctx, @fields)
          @result = nil
        end
      end
    end
  end
end
