module Leverage
  module Gating
    # A hold gating asks the transition function to open or close: a registry
    # hold reason, with the rule and the rule check that caused it. The check
    # is an index into Evaluation#checks for a check planned by the same
    # evaluate, or a rule_checks id, as Failure#rule_check_ref is (milestone 4
    # plan section 2.3): the row a rerun_limit hold names is planned with it.
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
