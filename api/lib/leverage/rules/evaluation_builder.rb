module Leverage
  module Rules
    # Red stub (WP3): an Evaluation with nothing planned.
    class EvaluationBuilder
      def self.call(_request)
        Gating::Evaluation.new(outcome: :completed, frozen_rule_version_ids: [], checks: [], jobs: [], failures: [],
          warnings: [], effects: [], holds_to_open: [], deferred_rule_ids: [])
      end
    end
  end
end
