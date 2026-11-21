module Leverage
  module Transitions
    module Entries
      # save_rule (PRD L342, L911; milestone 4 plan RD-5, RD-6, RD-24): the
      # owner saves a rule's fields as its next version (rule.changed); a
      # check made earlier keeps the version it ran against. Fields that do
      # not fit the rule are 422 invalid (RuleRecords.saved_version, checked
      # in load); a removed rule is invalid_state (RD-5).
      #
      # Params: id (the rule), and SaveRuleRequest's fields.
      class SaveRule < Entry
        def load(ctx)
          @rule = Rule.find_by(id: ctx.request.params["id"], workspace_id: ctx.workspace.id) || raise(NotFound, "No such rule")
          @fields = ctx.request.params.except("id")
          RuleRecords.saved_version(@rule, @fields)
        end

        def refusals(_ctx)
          causes = [ state_refusal(nil) ]
          causes << Refusal.new(code: Contract.state_machine.fetch("unlisted_pair_refusal")) if @rule.removed_at
          causes.compact
        end

        def perform(ctx)
          RuleRecords.save(ctx, @rule, @fields)
          @result = nil
        end
      end
    end
  end
end
