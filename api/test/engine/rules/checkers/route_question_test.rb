require_relative "../rules_test_support"

module Leverage
  module Rules
    class RouteQuestionTest < ActiveSupport::TestCase
      include TestSupport

      def evaluate
        task = scenario.task(state: "working")
        question = scenario.question(task, outcome: "open")
        Gating.evaluate(request_for(task, "question.asked", subject: question, params: { "text" => question.text }))
      end

      def assert_routed(effect)
        evaluation = evaluate
        assert_equal [ [ "applied", effect ] ], evaluation.checks.map { |check| [ check.result, check.effect ] }
        assert_equal [ effect ], evaluation.effects.map(&:effect)
        assert_empty evaluation.jobs
      end

      test "an enabled connected orchestrator gets the question without needing to have polled" do
        scenario.rule(key: "ask_orchestrator_first", origin: "shipped")
        scenario.seat(role: "orchestrator")

        assert_routed "to_orchestrator"
      end

      test "with no orchestrator in the workspace the app records the owner route" do
        scenario.rule(key: "ask_orchestrator_first", origin: "shipped")
        Scenario.new.seat(role: "orchestrator")
        scenario.seat(role: "planner")

        assert_routed "to_owner"
      end

      test "a removed or disabled orchestrator does not receive the question" do
        scenario.rule(key: "ask_orchestrator_first", origin: "shipped")
        scenario.seat(role: "orchestrator", enabled: false)
        scenario.seat(role: "orchestrator").update!(removed_at: scenario.database_now)

        assert_routed "to_owner"
      end

      test "turning off the rule leaves question routing to the caller without a row" do
        scenario.rule(key: "ask_orchestrator_first", origin: "shipped", enabled: false)
        scenario.seat(role: "orchestrator")

        evaluation = evaluate
        assert_empty evaluation.checks
        assert_empty evaluation.effects
      end
    end
  end
end
