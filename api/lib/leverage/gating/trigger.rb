module Leverage
  module Gating
    # Why a pending transition is gated again, and the rule check concerned
    # (nil when the last hold lifts).
    Trigger = Data.define(:kind, :rule_check_id) do
      const_set(:KINDS, %i[check_finished check_timed_out check_overridden check_rerun check_withdrawn rule_switched_off
                 hold_lifted].freeze)

      def initialize(kind:, rule_check_id:)
        raise ArgumentError, "kind must be one of #{self.class::KINDS.inspect}" unless self.class::KINDS.include?(kind)

        super
      end
    end
  end
end
