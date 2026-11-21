require_relative "../rules_test_support"

module Leverage
  module Rules
    class PauseProjectAtBudgetTest < ActiveSupport::TestCase
      include TestSupport

      setup { @rule = scenario.rule(key: "project_budget_pause", origin: "shipped") }

      def evaluate(task, subject: nil, project: nil)
        event = scenario.append("cost.reported", task: task, subject: subject, project_id: project&.id,
          payload: { tokens: 0, spend: 0 })
        request = request_for(task, "cost.reported", params: { "event_id" => event.id })
          .with(subject_kind: "event", subject_id: event.id, project_id: event.project_id)
        Gating.evaluate(request)
      end

      def assert_effects(evaluation, *effects)
        expected = effects.empty? ? [] : [ [ @rule.id, "applied", effects.first ] ]
        assert_equal expected, evaluation.checks.map { |check| [ check.rule_id, check.result, check.effect ] }
        assert_equal effects, evaluation.effects.map(&:effect)
        assert_empty evaluation.jobs
      end

      test "the project pauses at its budget and above, but no row is planned below it" do
        project = scenario.project(budget: 2, spent: 1)
        task = scenario.task(project: project)
        assert_effects evaluate(task)

        [ 2, 3 ].each do |spent|
          project.update!(spent: spent)
          assert_effects evaluate(task), "project_paused"
        end
      end

      test "a project without a budget or already paused gets no project effect" do
        project = scenario.project(spent: 2)
        task = scenario.task(project: project)
        assert_effects evaluate(task)

        project.update!(budget: 2, paused: true)
        assert_effects evaluate(task)
      end

      test "a seat report and a review verdict can hold a task at its cap" do
        task = scenario.task(state: "in_review")
        task.update!(budget_cap: 2, spent: 1)
        assert_effects evaluate(task)

        task.update!(spent: 2)
        assert_effects evaluate(task), "task_held"
        assert_effects evaluate(task, subject: Review.find_by!(task_id: task.id)), "task_held"
      end

      test "a job report can pause the project and cannot hold a task at its cap" do
        project = scenario.project(budget: 2, spent: 2)
        task = scenario.task(project: project)
        task.update!(budget_cap: 2, spent: 2)
        job = scenario.job(kind: "contract_draft", task: task)

        assert_effects evaluate(task, subject: job), "project_paused"
      end

      test "the project and task can both reach their budgets on one report" do
        project = scenario.project(budget: 2, spent: 2)
        task = scenario.task(project: project)
        task.update!(budget_cap: 1, spent: 1)

        assert_effects evaluate(task), "project_paused", "task_held"
      end

      test "a report cannot hold an ended task or reopen an existing budget hold" do
        %w[done cancelled].each do |state|
          task = scenario.task(state: state)
          task.update!(budget_cap: 1, spent: 1)
          assert_effects evaluate(task)
        end
        task = scenario.task(state: "working")
        task.update!(budget_cap: 1, spent: 1)
        open_hold(task, "budget")
        assert_effects evaluate(task)
      end

      test "turning off the budget rule stops both effects (RC-43)" do
        project = scenario.project(budget: 2, spent: 2)
        task = scenario.task(project: project)
        task.update!(budget_cap: 1, spent: 1)
        @rule.update!(enabled: false)

        assert_effects evaluate(task)
      end
    end
  end
end
