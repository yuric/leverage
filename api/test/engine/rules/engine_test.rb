require_relative "rules_test_support"

module Leverage
  module Rules
    # Rules::Engine (milestone 4 plan §2.1, RE-1, RT-2): the Leverage::Gating
    # implementation, seven calls each passed to the file of rules/ that
    # owns it. With no rule row it answers as milestone 2's rule-free
    # gating did (Gating::NoRules, deleted when the engine became the
    # production gating), so the rule-free loop of milestones 2 and 3 is
    # unchanged on it. Its parameters are the interface's, as the other
    # implementation, Gating::StandIn, has them.
    class EngineTest < ActiveSupport::TestCase
      include TestSupport

      CALLS = %i[evaluate reenter reenter_action briefing_rules built_by_providers provider_allowed? claimable_filter].freeze

      def engine = Engine.new

      def inputs_of(hook)
        Leverage::Contract.hooks.fetch("hooks").find { |entry| entry["hook"] == hook }.fetch("hashed_inputs").to_h { |key| [ key, nil ] }
      end

      def blank_request(task, hook, seat)
        Leverage::Gating::Request.new(workspace_id: task.workspace_id, task_id: task.id, project_id: nil, hook: hook, round: 0,
          subject_kind: nil, subject_id: nil, requester_kind: "seat", requester_id: seat.id, command_key: "k", inputs: inputs_of(hook))
      end

      test "it answers the seven calls of the gating interface with the interface's parameters" do
        reference = Leverage::Gating::StandIn
        CALLS.each do |call|
          assert_equal reference.instance_method(call).parameters, Engine.instance_method(call).parameters, call
        end
      end

      test "each call is one line that calls the file that owns it" do
        source = Rails.root.join("lib/leverage/rules/engine.rb").read
        owners = { evaluate: "EvaluationBuilder", reenter: "Reentry", reenter_action: "Reentry", briefing_rules: "BriefingRules",
                   built_by_providers: "ProviderRecord", provider_allowed?: "ProviderRule", claimable_filter: "ClaimFilter" }
        owners.each do |call, owner|
          body = source[/def #{Regexp.escape(call.to_s)}\(.*?\n(.*?)\n\s*end/m, 1]
          assert body, call
          assert_equal 1, body.strip.lines.size, call
          assert_includes body, "#{owner}.", call
        end
      end

      test "with no rule row every hook completes with nothing planned" do
        seat = scenario.seat
        task = scenario.task(state: "working", builder: seat)
        Leverage::Contract.registry.fetch("hooks").each do |hook|
          evaluation = engine.evaluate(blank_request(task, hook, seat))
          assert_equal :completed, evaluation.outcome, hook
          assert_equal [ [] ] * 8, evaluation.to_h.except(:outcome).values, hook
        end
        assert_raises(ArgumentError) { engine.evaluate(blank_request(task, "task.before_claim", seat).with(hook: "task.made_up")) }
      end

      test "with no rule row there are no briefing rules, every provider is allowed and a claim skips nothing" do
        builder = scenario.seat(credential: scenario.credential(provider: "claude"))
        task = scenario.task(state: "in_review", builder: builder)
        reviewer = scenario.seat(role: "reviewer", credential: scenario.credential(provider: "claude"))

        assert_equal [], engine.briefing_rules(task_id: task.id, seat_id: builder.id)
        Leverage::Contract.registry.fetch("credential_providers").each do |entry|
          assert engine.provider_allowed?(task_id: task.id, provider: entry.fetch("provider"))
        end
        [ builder, reviewer ].product(%i[task review]).each do |seat, kind|
          filter = engine.claimable_filter(seat_id: seat.id, kind: kind)
          assert_equal [ [], [] ], [ filter.excluded_task_ids, filter.excluded_review_ids ]
        end
        assert_raises(ArgumentError) { engine.claimable_filter(seat_id: builder.id, kind: :job) }
      end

      test "with no rule row nothing is pending, so nothing can be gated again" do
        assert_raises(ActiveRecord::RecordNotFound) do
          engine.reenter(pending_transition_id: SecureRandom.uuid, trigger: trigger)
        end
        assert_raises(ActiveRecord::RecordNotFound) do
          engine.reenter_action(action_id: SecureRandom.uuid, trigger: trigger)
        end
      end

      test "built_by_providers is the log's record of who built the task, rules or none (L448)" do
        task = scenario.task(state: "in_review", builder: scenario.seat(credential: scenario.credential(provider: "claude_api", kind: "api_token")))

        assert_equal [ "anthropic" ], engine.built_by_providers(task_id: task.id)
      end

      test "with no rule row it writes nothing and reads only" do
        seat = scenario.seat
        task = scenario.task(state: "working", builder: seat)
        statements = []
        subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
          next if %w[SCHEMA TRANSACTION].include?(payload[:name])

          statements << payload[:sql] unless payload[:sql].match?(/\A\s*(SELECT|WITH)\b/i)
        end
        engine.evaluate(blank_request(task, "task.before_submit", seat))
        engine.briefing_rules(task_id: task.id, seat_id: seat.id)
        engine.claimable_filter(seat_id: seat.id, kind: :task)
        engine.claimable_filter(seat_id: seat.id, kind: :review)
        engine.provider_allowed?(task_id: task.id, provider: "claude")
        assert_empty statements
      ensure
        ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
      end
    end
  end
end
