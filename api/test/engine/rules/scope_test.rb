require_relative "rules_test_support"

module Leverage
  module Rules
    # Rules::Scope (PRD L334, L364; plan RC-44, RD-22; milestone 4 plan §2.1
    # rule 3): whether a version's fixed scope covers a task, decided by the
    # server at no cost. "Let the checker decide" goes to the checker.
    class ScopeTest < ActiveSupport::TestCase
      include TestSupport

      def version(**fields) = scenario.current_version(scenario.rule(**fields))

      test "every task is covered by all_tasks" do
        assert_equal :covers, Scope.coverage(version(scope_kind: "all_tasks"), scenario.task)
      end

      test "let the checker decide goes to the checker for a model rule" do
        assert_equal :checker_decides, Scope.coverage(version(scope_kind: "checker_decides"), scenario.task)
      end

      test "named projects cover a task of a named project, never a task with no project (RC-44)" do
        named = scenario.project
        other = scenario.project(name: "Another made-up project")
        rule_version = version(scope_kind: "named_projects", scope_values: [ named.id ])

        assert_equal :covers, Scope.coverage(rule_version, scenario.task(project: named))
        assert_equal :not_covered, Scope.coverage(rule_version, scenario.task(project: other))
        assert_equal :not_covered, Scope.coverage(rule_version, scenario.task)
      end

      test "outward action kinds cover a task that ends in one of them" do
        rule_version = version(scope_kind: "action_kinds", scope_values: [ "pay" ])
        task = scenario.task
        action(task, kind: "publish")
        assert_equal :not_covered, Scope.coverage(rule_version, task)

        action(task, kind: "pay", position: 2)
        assert_equal :covers, Scope.coverage(rule_version, task)
      end

      test "a waived or revoked action does not count" do
        rule_version = version(scope_kind: "action_kinds", scope_values: [ "pay" ])
        task = scenario.task
        action(task, kind: "pay", state: "waived")
        action(task, kind: "pay", state: "revoked", position: 2)

        assert_equal :not_covered, Scope.coverage(rule_version, task)
      end

      test "at ready to start the requested actions count, not the stored ones" do
        rule_version = version(hook: "task.before_ready", scope_kind: "action_kinds", scope_values: [ "send" ])
        task = scenario.task
        action(task, kind: "send")
        inputs = request_for(task, "task.before_ready", params: contract_params(actions: [ { "kind" => "publish", "description" => "x" } ])).inputs

        assert_equal :not_covered, Scope.coverage(rule_version, task, inputs)
        inputs = request_for(task, "task.before_ready", params: contract_params(actions: [ { "kind" => "send", "description" => "x" } ])).inputs
        assert_equal :covers, Scope.coverage(rule_version, task, inputs)
      end

      test "before anything goes out the scope is decided for each action" do
        rule_version = version(hook: "action.requested", scope_kind: "action_kinds", scope_values: [ "send" ])
        task = scenario.task
        sending = action(task, kind: "send")
        publishing = action(task, kind: "publish", position: 2)

        sending_inputs = request_for(task, "action.requested", params: { "aid" => sending.id }).inputs
        publishing_inputs = request_for(task, "action.requested", params: { "aid" => publishing.id }).inputs
        assert_equal :covers, Scope.coverage(rule_version, task, sending_inputs)
        assert_equal :not_covered, Scope.coverage(rule_version, task, publishing_inputs)
        assert_equal :covers, Scope.coverage(rule_version, task), "a briefing still describes the whole task"
      end

      test "the other three moments after Ready use the task's actions" do
        task = scenario.task
        %w[task.before_claim task.before_submit task.before_done].each do |hook|
          rule_version = version(hook: hook, scope_kind: "action_kinds", scope_values: [ "send" ])
          assert_equal :not_covered, Scope.coverage(rule_version, task, {})
        end
        action(task, kind: "send")
        %w[task.before_claim task.before_submit task.before_done].each do |hook|
          rule_version = version(hook: hook, scope_kind: "action_kinds", scope_values: [ "send" ])
          assert_equal :covers, Scope.coverage(rule_version, task, {})
        end
      end

      test "covers? is true for both covering answers" do
        task = scenario.task
        assert Scope.covers?(version(scope_kind: "checker_decides"), task)
        assert Scope.covers?(version(scope_kind: "all_tasks"), task)
        refute Scope.covers?(version(scope_kind: "named_projects", scope_values: []), task)
      end
    end
  end
end
