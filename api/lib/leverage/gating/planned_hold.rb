module Leverage
  module Gating
    # A hold gating asks the transition function to open or close: a registry
    # hold reason, with the rule and the rule check that caused it.
    PlannedHold = Data.define(:reason, :rule_id, :rule_check_id) do
      def initialize(reason:, **fields)
        unless Contract.registry.fetch("hold_reasons").any? { |entry| entry["reason"] == reason }
          raise ArgumentError, "unknown hold reason #{reason.inspect}"
        end

        super(reason: reason, **fields)
      end
    end
  end
end
