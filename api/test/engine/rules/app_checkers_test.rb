require_relative "rules_test_support"

module Leverage
  module Rules
    # Rules::AppCheckers (milestone 4 plan §2.1, RD-8): the registry from a
    # checker_function to its class, and the one list of what acts in this
    # milestone. All five app checkers and both model rules act.
    class AppCheckersTest < ActiveSupport::TestCase
      include TestSupport

      def shipped_version(key)
        rule = scenario.with_shipped_rules.find { |row| row.key == key }
        scenario.current_version(rule)
      end

      test "all five shipped app checkers are built" do
        functions = Shipped.all.filter_map(&:checker_function)
        assert_equal %w[escalate_after_failed_reviews minimum_criteria_count pause_project_at_budget
                        refuse_reviewer_of_building_provider route_question], functions.sort
        assert_equal functions.sort, AppCheckers::BUILT.keys.sort
        functions.each { |function| assert AppCheckers.built?(function), function }
      end

      test "a model rule runs; an app rule runs only when its function is built" do
        versions = scenario.with_shipped_rules.to_h { |rule| [ rule.key, scenario.current_version(rule) ] }

        runs = versions.select { |_, version| AppCheckers.runs?(version) }.keys
        assert_equal versions.keys, runs
        refute AppCheckers.runs?(versions.fetch("acceptance_criteria").dup.tap { |version| version.checker_function = "unbuilt" })
      end

      test "all seven shipped rules act (AP-1)" do
        versions = scenario.with_shipped_rules.to_h { |rule| [ rule.key, scenario.current_version(rule) ] }

        acting = versions.select { |_, version| AppCheckers.acts?(version) }.keys
        assert_equal versions.keys, acting
      end

      test "a custom model rule acts at each of the five offered moments" do
        Contract.registry.fetch("custom_rule_hooks").each do |hook|
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
        version = shipped_version("acceptance_criteria").dup
        version.checker_function = "unbuilt"
        task = scenario.task
        assert_raises(ArgumentError) do
          AppCheckers.check(version, request: request_for(task, "task.before_ready", params: contract_params), task: task)
        end
      end
    end
  end
end
