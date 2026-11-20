module Leverage
  module Reads
    # list_rules (Settings, Rules; openapi.json RulesList; milestone 4 plan
    # §2.3, RD-26): each rule with its current version, its sentence, its
    # moment, whether it acts, and its counts.
    #
    # First version (milestone 4 plan §4, the hand-over table): no rule.
    # WP11 writes it.
    module Rules
      module_function

      def call(workspace_id)
        { "rules" => [] }
      end
    end
  end
end
