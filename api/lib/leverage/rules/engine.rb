module Leverage
  module Rules
    # The Leverage::Gating implementation the initializer sets once WP12
    # names it (milestone 4 plan §2.1, RE-1): seven calls, each one line
    # that calls the file of rules/ that owns it. It reads and plans; it
    # never writes (one_writer_test.rb).
    #
    # First version (milestone 4 plan §4, the hand-over table): each call
    # answers as Gating::NoRules does. WP3 writes it.
    class Engine
      def initialize
        @no_rules = Gating::NoRules.new
      end

      def evaluate(request)
        @no_rules.evaluate(request)
      end

      def reenter(pending_transition_id:, trigger:)
        @no_rules.reenter(pending_transition_id: pending_transition_id, trigger: trigger)
      end

      def reenter_action(action_id:, trigger:)
        @no_rules.reenter_action(action_id: action_id, trigger: trigger)
      end

      def briefing_rules(task_id:, seat_id:, review_id: nil)
        @no_rules.briefing_rules(task_id: task_id, seat_id: seat_id, review_id: review_id)
      end

      def built_by_providers(task_id:)
        @no_rules.built_by_providers(task_id: task_id)
      end

      def provider_allowed?(task_id:, provider:)
        @no_rules.provider_allowed?(task_id: task_id, provider: provider)
      end

      def claimable_filter(seat_id:, kind:)
        @no_rules.claimable_filter(seat_id: seat_id, kind: kind)
      end
    end
  end
end
