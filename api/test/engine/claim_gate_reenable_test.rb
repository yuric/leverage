require "test_helper"
require_relative "entries/gated_flow_support"

# A task three seats failed a blocking task.before_claim gate on is held
# with claim_gate_failed (PRD L166, L393). Turning the rule off closes the
# hold; turning it on again brings the stored failures back, and with them
# the hold and its Needs you item, so the task is never left in Ready with
# every seat skipping it and nothing for the owner (milestone 4 review,
# finding 5).
class ClaimGateReenableTest < ActiveSupport::TestCase
  include GatedFlowSupport

  setup do
    use_scenario
    @orchestrator = online_orchestrator
    @rule = model_rule(hook: "task.before_claim")
    @task = scenario.task(state: "ready")
    @seats = Array.new(3) { |index| scenario.seat(role: "builder", name: "Made-up builder #{index}") }
    @seats.each do |seat|
      assert_equal :pending, seat_command(seat, "claim").outcome
      answer_next(@orchestrator, FAILED)
    end
    assert_equal [ "claim_gate_failed" ], open_holds(@task).map(&:reason)
  end

  def claim_items = open_items(@task).select { |item| item.kind == "refused_for_every_agent" }

  test "turning the rule off and on again reopens claim_gate_failed with its item" do
    assert_completed(owner_command("disable_rule", { "id" => @rule.id }))
    assert_empty open_holds(@task)

    assert_completed(owner_command("enable_rule", { "id" => @rule.id }))

    hold = open_holds(@task).sole
    assert_equal [ "claim_gate_failed", @rule.id ], [ hold.reason, hold.rule_id ]
    failed = RuleCheck.where(task_id: @task.id, rule_id: @rule.id, result: "failed").order(:created_at).last
    assert_equal failed.id, hold.rule_check_id
    assert_equal [ hold.id ], claim_items.map(&:hold_id)
    assert_equal({ "rule_id" => @rule.id, "rule_check_id" => failed.id }, claim_items.sole.facts)
    assert_equal "ready", @task.reload.state
  end

  test "turning on a rule with fewer than three failing seats opens nothing" do
    other = scenario.task(state: "ready")
    first = RuleCheck.find_by!(task_id: @task.id, subject_id: @seats.first.id)
    assert_completed(owner_command("override_check", { "id" => first.id, "reason" => "A made-up reason." }))
    assert_completed(owner_command("disable_rule", { "id" => @rule.id }))

    assert_completed(owner_command("enable_rule", { "id" => @rule.id }))

    assert_empty open_holds(@task)
    assert_empty open_holds(other)
  end
end
