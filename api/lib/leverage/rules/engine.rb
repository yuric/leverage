module Leverage
  module Rules
    # The Leverage::Gating implementation the initializer sets once WP12
    # names it (milestone 4 plan §2.1, RE-1): seven calls, each one line
    # that calls the file of rules/ that owns it. It reads and plans; it
    # never writes (one_writer_test.rb).
    class Engine
      def evaluate(request)
        EvaluationBuilder.call(request)
      end

      def reenter(pending_transition_id:, trigger:)
        Reentry.call(pending_transition_id: pending_transition_id, trigger: trigger)
      end

      def reenter_action(action_id:, trigger:)
        Reentry.action(action_id: action_id, trigger: trigger)
      end

      def briefing_rules(task_id:, seat_id:, review_id: nil)
        BriefingRules.call(task_id: task_id, seat_id: seat_id, review_id: review_id)
      end

      def built_by_providers(task_id:)
        ProviderRecord.groups(task_id)
      end

      def provider_allowed?(task_id:, provider:)
        ProviderRule.allowed?(task_id, provider)
      end

      def claimable_filter(seat_id:, kind:)
        ClaimFilter.call(seat_id: seat_id, kind: kind)
      end
    end
  end
end
