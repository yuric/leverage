module Leverage
  module Reads
    # The timing questions of PRD L314 to L317, per rule (milestone 4 plan
    # RD-26): what each rule's checks cost in time, tokens and spend.
    #
    # First version (milestone 4 plan §4, the hand-over table): an empty
    # list. WP11 writes it.
    module RuleTiming
      module_function

      # rule_id: - one rule's answer, or nil for every rule's.
      def call(workspace_id, rule_id: nil)
        []
      end
    end
  end
end
