module Leverage
  module Gating
    # The gating of a workspace with no rules: the production
    # implementation for milestone 2 (plan EN-5), set by
    # config/initializers/leverage_gating.rb. Every hook completes with no
    # check, job, failure, warning, effect or hold; there are no briefing
    # rules and no built-by providers; every provider is allowed; a claim
    # filters nothing out. Nothing can be pending, and no outward action
    # exists (SC-3), so neither reenter call can be reached. It reads and
    # writes nothing. Milestone 4 replaces this one class.
    class NoRules
      # reenter or reenter_action was called, which nothing in a workspace
      # with no rules can cause.
      class NothingPending < StandardError; end

      def evaluate(request)
        unless Contract.registry.fetch("hooks").include?(request.hook)
          raise ArgumentError, "unknown hook #{request.hook.inspect}"
        end

        Evaluation.new(outcome: :completed, frozen_rule_version_ids: [], checks: [], jobs: [], failures: [], warnings: [],
          effects: [], holds_to_open: [], deferred_rule_ids: [])
      end

      def reenter(pending_transition_id:, trigger:)
        raise NothingPending, "no transition can be pending without rules (#{pending_transition_id})"
      end

      def reenter_action(action_id:, trigger:)
        raise NothingPending, "no outward action exists in milestone 2 (#{action_id})"
      end

      def briefing_rules(task_id:, seat_id:, review_id: nil) = []

      def built_by_providers(task_id:) = []

      def provider_allowed?(task_id:, provider:) = true

      def claimable_filter(seat_id:, kind:)
        raise ArgumentError, "kind must be :task or :review, got #{kind.inspect}" unless %i[task review].include?(kind)

        ClaimFilter.new(excluded_task_ids: [], excluded_review_ids: [])
      end
    end
  end
end
