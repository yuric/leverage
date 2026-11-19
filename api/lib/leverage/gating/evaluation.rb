module Leverage
  module Gating
    # What evaluate decided. outcome is :completed or :pending (pending only
    # when a blocking model check is planned). checks are PlannedCheck rows,
    # jobs PlannedJob rows, failures and warnings Failure values (warnings are
    # failed warn rules, which let the transition through), effects Effect
    # values of the policy rules, holds_to_open PlannedHold values.
    # frozen_rule_version_ids are the rule versions frozen for this request.
    # deferred_rule_ids are the policy rules at action.requested that wait
    # for the action's gates (PRD L138); Gating.reenter_action plans them.
    Evaluation = Data.define(:outcome, :frozen_rule_version_ids, :checks, :jobs, :failures, :warnings, :effects,
                             :holds_to_open, :deferred_rule_ids) do
      const_set(:OUTCOMES, %i[completed pending].freeze)

      def initialize(outcome:, frozen_rule_version_ids:, checks:, jobs:, failures:, warnings:, effects:, holds_to_open:,
                     deferred_rule_ids: [])
        raise ArgumentError, "outcome must be one of #{self.class::OUTCOMES.inspect}" unless self.class::OUTCOMES.include?(outcome)

        super(outcome: outcome, frozen_rule_version_ids: frozen_rule_version_ids.dup.freeze, checks: checks.dup.freeze,
              jobs: jobs.dup.freeze, failures: failures.dup.freeze, warnings: warnings.dup.freeze,
              effects: effects.dup.freeze, holds_to_open: holds_to_open.dup.freeze,
              deferred_rule_ids: deferred_rule_ids.dup.freeze)
      end
    end
  end
end
