require_relative "rules_test_support"

module Leverage
  module Rules
    # Rules::RerunLimit (PRD L422; SM-35; milestone 4 plan RD-45, RD-46): a
    # model-checked gate runs at most rerun_limit times per round on
    # changed inputs. The count is of distinct input hashes run for one
    # rule, hook, round and subject since the owner last changed the
    # contract; a timeout's retry is an attempt, not a run.
    class RerunLimitTest < ActiveSupport::TestCase
      include TestSupport

      setup do
        @rule = model_gate("task.before_submit")
        @task = scenario.task(state: "working")
      end

      def run_on(hash, rule: @rule, result: "failed", **options)
        scenario.rule_check(@task, rule: rule, result: result, input_hash: hash, **options)
      end

      def reached?(hash, rule: @rule, subject: nil, owner_request: false, hook: "task.before_submit")
        RerunLimit.reached?(task: @task, rule_id: rule.id, hook: hook, round: @task.round, subject_kind: subject && "seat",
          subject_id: subject&.id, input_hash: hash, owner_request: owner_request)
      end

      def owner_changes_contract
        scenario.append("task.contract_changed", task: @task, actor_kind: "owner", actor_id: scenario.owner.id,
          payload: { contract_version: @task.contract_version, minimum_strength_rank: nil, added_criterion_ids: [],
                     reset_criterion_ids: [], removed_criterion_ids: [], added_action_ids: [], removed_action_ids: [] })
      end

      test "three distinct inputs run; the fourth reaches the limit" do
        run_on("1" * 64)
        run_on("2" * 64)
        refute reached?("3" * 64)

        run_on("3" * 64)
        assert reached?("4" * 64)
        assert_equal [ "1" * 64, "2" * 64, "3" * 64 ], RerunLimit.runs(task: @task, rule_id: @rule.id,
          hook: "task.before_submit", round: @task.round, subject_kind: nil, subject_id: nil).sort
      end

      test "inputs already run are not a new run, and a timeout's retry is an attempt" do
        run_on("1" * 64, attempts: 2, result: "error")
        run_on("2" * 64)
        run_on("3" * 64)

        refute reached?("2" * 64)
        assert reached?("5" * 64)
      end

      test "the count is per rule, round and subject" do
        other = model_gate("task.before_submit")
        3.times { |index| run_on((index + 1).to_s * 64, rule: other) }
        refute reached?("4" * 64)

        3.times { |index| run_on((index + 1).to_s * 64, round: 1) }
        refute reached?("4" * 64)

        seat = scenario.seat
        3.times { |index| run_on((index + 1).to_s * 64, subject: seat) }
        refute reached?("4" * 64)
        assert reached?("4" * 64, subject: seat)
      end

      test "an owner's contract change starts the count again (RD-46)" do
        3.times { |index| run_on((index + 1).to_s * 64) }
        assert reached?("4" * 64)

        owner_changes_contract
        refute reached?("4" * 64)
        run_on("5" * 64)
        run_on("6" * 64)
        run_on("7" * 64)
        assert reached?("8" * 64)
      end

      test "a planner's contract change does not start the count again" do
        planner = scenario.planner
        3.times { |index| run_on((index + 1).to_s * 64) }
        scenario.append("task.contract_changed", task: @task, actor_kind: "seat", actor_id: planner.id,
          payload: { contract_version: @task.contract_version, minimum_strength_rank: nil, added_criterion_ids: [],
                     reset_criterion_ids: [], removed_criterion_ids: [], added_action_ids: [], removed_action_ids: [] })

        assert reached?("4" * 64)
      end

      test "at ready to start a planner's fourth draft reaches the limit and the owner's request always runs" do
        ready_rule = model_gate("task.before_ready", route: "owner")
        @task = scenario.task
        3.times { |index| run_on((index + 1).to_s * 64, rule: ready_rule) }

        assert reached?("4" * 64, rule: ready_rule, hook: "task.before_ready")
        refute reached?("4" * 64, rule: ready_rule, hook: "task.before_ready", owner_request: true)
      end

      test "a row held at the limit was never run and is not counted" do
        3.times { |index| run_on((index + 1).to_s * 64) }
        RuleCheck.create!(workspace_id: scenario.workspace_id, task_id: @task.id, rule_id: @rule.id,
          rule_version_id: scenario.current_version(@rule).id, hook: "task.before_submit", round: 0, input_hash: "4" * 64)

        assert_equal 3, RerunLimit.runs(task: @task, rule_id: @rule.id, hook: "task.before_submit", round: 0,
          subject_kind: nil, subject_id: nil).size
      end

      test "the limit is the workspace's setting" do
        scenario.workspace.update!(rerun_limit: 1)
        run_on("1" * 64)

        assert reached?("2" * 64)
      end
    end
  end
end
