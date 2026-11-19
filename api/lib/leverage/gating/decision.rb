module Leverage
  module Gating
    # What reenter decided for a pending transition, or reenter_action for an
    # outward action. action is :complete, :refuse (failures say why and to
    # whom), :cancel (the inputs changed: the checks in checks_to_withdraw are
    # withdrawn) or :keep_pending. checks and jobs are what reenter_action
    # plans when an action's gates have all cleared: the approval policy's
    # PlannedCheck rows and PlannedJob rows (rule_check_ref indexes checks);
    # reenter leaves them empty.
    Decision = Data.define(:action, :failures, :effects, :holds_to_open, :holds_to_close, :checks_to_withdraw, :checks,
                           :jobs) do
      const_set(:ACTIONS, %i[complete refuse cancel keep_pending].freeze)

      def initialize(action:, failures:, effects:, holds_to_open:, holds_to_close:, checks_to_withdraw:, checks: [], jobs: [])
        raise ArgumentError, "action must be one of #{self.class::ACTIONS.inspect}" unless self.class::ACTIONS.include?(action)

        super(action: action, failures: failures.dup.freeze, effects: effects.dup.freeze,
              holds_to_open: holds_to_open.dup.freeze, holds_to_close: holds_to_close.dup.freeze,
              checks_to_withdraw: checks_to_withdraw.dup.freeze, checks: checks.dup.freeze, jobs: jobs.dup.freeze)
      end
    end
  end
end
