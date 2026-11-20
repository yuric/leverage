require_relative "rules_test_support"

module Leverage
  module Rules
    # Rules::StoredResults (PRD L408, L421, L423; DB-25; milestone 4 plan
    # §2.1 rule 4): the rule_checks row of an identity (task, rule version,
    # hook, round, subject, input hash) and what it means for a new request.
    class StoredResultsTest < ActiveSupport::TestCase
      include TestSupport

      setup do
        @rule = model_gate("task.before_submit")
        @task = scenario.task(state: "working")
      end

      def stored(result: nil, **options)
        scenario.rule_check(@task, rule: @rule, result: result, input_hash: "a" * 64, **options)
      end

      def find(input_hash: "a" * 64, subject: nil, round: @task.round)
        StoredResults.find(task_id: @task.id, rule_version_id: scenario.current_version(@rule).id, hook: "task.before_submit",
          round: round, subject_kind: subject && "seat", subject_id: subject&.id, input_hash: input_hash)
      end

      test "the row of the identity is found, a null subject matching a null subject" do
        row = stored(result: "passed")

        assert_equal row.id, find.id
        assert_nil find(input_hash: "b" * 64)
        assert_nil find(round: 1)
        assert_nil find(subject: scenario.seat)
      end

      test "a passed or not applicable row is reused as it is" do
        assert_equal :passed, StoredResults.use(stored(result: "passed"))
        @task = scenario.task(state: "working")
        assert_equal :passed, StoredResults.use(stored(result: "not_applicable"))
      end

      test "a failed row is a failure; overridden, it counts as cleared" do
        failed = stored(result: "failed", reason: "A made-up reason.")
        assert_equal :failed, StoredResults.use(failed)

        assert_equal :cleared, StoredResults.use(override(failed))
      end

      test "an error or a withdrawn row is run again as a new attempt" do
        assert_equal :rerun, StoredResults.use(stored(result: "error"))
        @task = scenario.task(state: "working")
        assert_equal :rerun, StoredResults.use(stored(result: "withdrawn"))
      end

      test "an overridden error, and an overridden row held at the re-run limit, count as cleared" do
        assert_equal :cleared, StoredResults.use(override(stored(result: "error")))
        held = RuleCheck.create!(workspace_id: scenario.workspace_id, task_id: @task.id, rule_id: @rule.id,
          rule_version_id: scenario.current_version(@rule).id, hook: "task.before_submit", round: 0, input_hash: "c" * 64)
        assert_equal :running, StoredResults.use(held)
        assert_equal :cleared, StoredResults.use(override(held))
      end

      test "a row with no result is still running" do
        assert_equal :running, StoredResults.use(stored)
      end

      test "an applied policy row is reused with its effect" do
        assert_equal :applied, StoredResults.use(RuleCheck.new(result: "applied", effect: "refused"))
      end

      test "no row is nothing to reuse" do
        assert_nil StoredResults.use(nil)
      end
    end
  end
end
