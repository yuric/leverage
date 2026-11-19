module Leverage
  module Gating
    # What reenter decided for a pending transition. action is :complete,
    # :refuse (failures say why and to whom), :cancel (the inputs changed: the
    # checks in checks_to_withdraw are withdrawn) or :keep_pending.
    Decision = Data.define(:action, :failures, :effects, :holds_to_open, :holds_to_close, :checks_to_withdraw) do
      const_set(:ACTIONS, %i[complete refuse cancel keep_pending].freeze)

      def initialize(action:, failures:, effects:, holds_to_open:, holds_to_close:, checks_to_withdraw:)
        raise ArgumentError, "action must be one of #{self.class::ACTIONS.inspect}" unless self.class::ACTIONS.include?(action)

        super(action: action, failures: failures.dup.freeze, effects: effects.dup.freeze,
              holds_to_open: holds_to_open.dup.freeze, holds_to_close: holds_to_close.dup.freeze,
              checks_to_withdraw: checks_to_withdraw.dup.freeze)
      end
    end
  end
end
