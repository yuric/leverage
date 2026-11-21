require "test_helper"
require_relative "entries/gated_flow_support"

# A waiting submit or pass completes when what it waits on settles, even
# though the briefing changed meanwhile (PRD L379: "the transition
# completes if nothing else blocks it", an edited rule "does not affect
# it"; L194-L195 and L422, the "turn the rule off" choices). Turning a
# rule off, removing it or saving it changes the rules in the briefing,
# and so its hash; the waiting command was sent on the briefing it had,
# and its holder cannot acknowledge again while it waits. Re-entry
# therefore does not refuse it for the briefing (milestone 4 review,
# finding 1).
class ReentryCompletesTest < ActiveSupport::TestCase
  include GatedFlowSupport

  setup do
    use_scenario
    @orchestrator = online_orchestrator
    @builder = scenario.seat(role: "builder")
  end

  def submit_waiting(rule_count: 1)
    rules = Array.new(rule_count) { |index| model_rule(hook: "task.before_submit", name: "Made-up rule #{index}") }
    task = ready_to_submit(@builder)
    key = new_key
    assert_equal :pending, seat_command(@builder, "submit", submit_body(task), key: key).outcome
    [ rules, task, key ]
  end

  def assert_submitted(task, key)
    assert_equal "in_review", task.reload.state, "the submit completes"
    row = command_row(@builder, key)
    assert_equal [ "completed", nil ], [ row.outcome, row.refusal ]
  end

  %w[disable_rule remove_rule].each do |command|
    test "a submit waiting on its only rule completes when #{command} takes the rule away" do
      (rule,), task, key = submit_waiting

      assert_completed(owner_command(command, { "id" => rule.id }))

      assert_submitted(task, key)
    end

    test "a pass waiting at task.before_done completes when #{command} takes its rule away" do
      rule = model_rule(hook: "task.before_done")
      reviewer = scenario.seat(role: "reviewer", provider: "codex")
      task, review = ready_for_verdict(reviewer)
      key = new_key
      assert_equal :pending, seat_command(reviewer, "pass_review", pass_body(review), key: key).outcome

      assert_completed(owner_command(command, { "id" => rule.id }))

      assert_equal "done", task.reload.state
      assert_equal "completed", command_row(reviewer, key).outcome
    end
  end

  # A SaveRuleRequest body that rewords the rule's instruction.
  def reworded(rule)
    version = scenario.current_version(rule)
    { "id" => rule.id, "name" => version.name, "instruction" => "A made-up reworded instruction.", "parameters" => {},
      "scope" => { "kind" => "all_tasks", "project_ids" => nil, "action_kinds" => nil }, "on_fail" => "block",
      "route" => version.route || "builder", "queue_timeout_seconds" => nil, "run_timeout_seconds" => nil }
  end

  test "a submit completes when the rule it waits on is saved and its check then passes" do
    (rule,), task, key = submit_waiting
    assert_completed(owner_command("save_rule", reworded(rule)))
    assert_equal "working", task.reload.state, "an edited rule does not affect the request (L379)"

    answer_next(@orchestrator, PASSED)

    assert_submitted(task, key)
  end

  test "a submit completes when a rule at another moment is saved while its check runs" do
    _, task, key = submit_waiting
    other = model_rule(hook: "task.before_done", name: "Made-up rule at Done")
    assert_completed(owner_command("save_rule", reworded(other)))

    answer_next(@orchestrator, PASSED)

    assert_submitted(task, key)
  end

  test "with two rules, turning one off while the other runs completes the submit when the other passes" do
    (first, _second), task, key = submit_waiting(rule_count: 2)

    assert_completed(owner_command("disable_rule", { "id" => first.id }))
    assert_equal "working", task.reload.state, "the other check still runs"
    assert_equal 1, Job.where(workspace_id: scenario.workspace_id, kind: "rule_check", state: "queued").count

    answer_next(@orchestrator, PASSED)

    assert_submitted(task, key)
  end

  test "the check_error choice Turn the rule off completes the submit" do
    (rule,), task, key = submit_waiting
    check = RuleCheck.find_by!(task_id: task.id, rule_id: rule.id)
    error_check(check)
    assert_equal [ "check_error" ], open_holds(task).map(&:reason)

    assert_completed(owner_command("disable_rule", { "id" => rule.id }))

    assert_submitted(task, key)
    assert_empty open_holds(task)
  end

  test "the rerun_limit choice Turn the rule off completes the submit" do
    rule = model_rule(hook: "task.before_submit")
    task = ready_to_submit(@builder)
    3.times do |run|
      acknowledge(@builder, task)
      assert_equal :pending, seat_command(@builder, "submit", submit_body(task, note: "Made-up note #{run}.")).outcome
      answer_next(@orchestrator, FAILED)
      assert_equal "working", task.reload.state
    end
    acknowledge(@builder, task)
    key = new_key
    assert_equal :pending, seat_command(@builder, "submit", submit_body(task, note: "Made-up note 3."), key: key).outcome
    assert_equal [ "rerun_limit" ], open_holds(task).map(&:reason)

    assert_completed(owner_command("disable_rule", { "id" => rule.id }))

    assert_submitted(task, key)
    assert_empty open_holds(task)
  end
end
