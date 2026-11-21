require_relative "../rules_test_support"

module Leverage
  module Rules
    module Checkers
      # Checkers::MinimumCriteriaCount, the function of "Every task needs
      # acceptance criteria" (PRD L436: minimum count, default 1, not
      # counting the review): at task.before_ready it counts the build
      # criteria of the requested contract; its reason names the count.
      class MinimumCriteriaCountTest < ActiveSupport::TestCase
        include Leverage::Rules::TestSupport

        def version(minimum = nil)
          parameters = minimum.nil? ? {} : { "minimum_count" => minimum }
          scenario.current_version(app_gate("task.before_ready", "minimum_criteria_count", parameters: parameters))
        end

        def check(version, kinds, task: scenario.task)
          MinimumCriteriaCount.call(version: version, task: task,
            request: request_for(task, "task.before_ready", params: contract_params(kinds)))
        end

        test "it passes with as many build criteria as the minimum, and fails with fewer" do
          two = version(2)

          assert_equal "passed", check(two, %w[build build review]).result
          assert_equal "passed", check(two, %w[build build build]).result
          assert_equal "failed", check(two, %w[build review]).result
        end

        test "the review criterion does not count" do
          assert_equal "failed", check(version(1), %w[review review]).result
          assert_equal "passed", check(version(1), %w[review build]).result
        end

        test "the minimum is 1 when the version names none" do
          assert_equal "failed", check(version, %w[review]).result
          assert_equal "passed", check(version, %w[build review]).result
        end

        test "its reason names the count and the minimum; a gate has no effect" do
          failed = check(version(2), %w[build review])
          passed = check(version(1), %w[build build review])

          assert_equal "The contract has 1 acceptance criterion besides the review; this rule needs at least 2.", failed.reason
          assert_equal "The contract has 2 acceptance criteria besides the review; this rule needs at least 1.", passed.reason
          assert_nil failed.effect
        end

        test "at another hook it counts the task's own live build criteria" do
          task = scenario.task(state: "working", criteria: %w[build build review])
          rule_version = scenario.current_version(app_gate("task.before_submit", "minimum_criteria_count",
            parameters: { "minimum_count" => 2 }))
          request = request_for(task, "task.before_submit", params: { "handoff_note" => "Made-up note." })

          assert_equal "passed", MinimumCriteriaCount.call(version: rule_version, task: task, request: request).result
          Criterion.where(task_id: task.id, kind: "build").first.update!(removed_at: scenario.database_now)
          assert_equal "failed", MinimumCriteriaCount.call(version: rule_version, task: task, request: request).result
        end
      end
    end
  end
end
