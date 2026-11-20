require_relative "rules_test_support"

module Leverage
  module Rules
    # Rules::AppCheckers (milestone 4 plan §2.1, RD-8): the registry from a
    # checker_function to its class, and the one list of what acts in this
    # milestone. Two of the five functions are built; an app rule whose
    # function is not built runs nowhere, and the approval rule, a model
    # rule, waits for the outward actions of milestone 5.
    class AppCheckersTest < ActiveSupport::TestCase
      include TestSupport

      def shipped_version(key)
        rule = scenario.with_shipped_rules.find { |row| row.key == key }
        scenario.current_version(rule)
      end

      test "two functions are built, and every function of the shipped rules is named" do
        assert_equal %w[minimum_criteria_count refuse_reviewer_of_building_provider], AppCheckers::BUILT.keys.sort
        functions = Shipped.all.filter_map(&:checker_function)
        assert_equal %w[escalate_after_failed_reviews minimum_criteria_count pause_project_at_budget
                        refuse_reviewer_of_building_provider route_question], functions.sort
        functions.each { |function| assert_equal AppCheckers::BUILT.key?(function), AppCheckers.built?(function), function }
      end

      test "a model rule runs; an app rule runs only when its function is built" do
        versions = scenario.with_shipped_rules.to_h { |rule| [ rule.key, scenario.current_version(rule) ] }

        runs = versions.select { |_, version| AppCheckers.runs?(version) }.keys
        assert_equal %w[acceptance_criteria specific_details different_provider_review orchestrator_approves_actions], runs
      end

      test "three shipped rules act in this milestone; the other four start working later (RD-8)" do
        versions = scenario.with_shipped_rules.to_h { |rule| [ rule.key, scenario.current_version(rule) ] }

        acting = versions.select { |_, version| AppCheckers.acts?(version) }.keys
        assert_equal %w[acceptance_criteria specific_details different_provider_review], acting
      end

      test "a custom model rule acts at each of the four moments offered now" do
        %w[task.before_ready task.before_claim task.before_submit task.before_done].each do |hook|
          assert AppCheckers.acts?(scenario.current_version(model_gate(hook))), hook
        end
      end

      test "check runs the version's function on the request" do
        version = shipped_version("acceptance_criteria")
        task = scenario.task
        result = AppCheckers.check(version, request: request_for(task, "task.before_ready", params: contract_params(%w[review])),
          task: task)

        assert_equal "failed", result.result
        assert_nil result.effect
      end

      test "check refuses a function that is not built" do
        version = shipped_version("escalate_after_failed_reviews")
        task = scenario.task
        assert_raises(ArgumentError) do
          AppCheckers.check(version, request: request_for(task, "task.before_ready", params: contract_params), task: task)
        end
      end
    end
  end
end
