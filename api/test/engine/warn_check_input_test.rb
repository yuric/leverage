require "test_helper"
require_relative "entries/gated_flow_support"

# A warn rule's model check judges what the request held, even when no
# command waits on it (PRD L428, RC-16; milestone 4 review, finding 8): a
# warn-only rule leaves no pending transition, and a warn check claimed
# after a blocking check settled the move finds the transition's stored
# request emptied. The request's text the check needs is stored on its job
# when it is queued, and the inputs it hands are those its hash was taken
# over.
class WarnCheckInputTest < ActiveSupport::TestCase
  include GatedFlowSupport

  setup do
    use_scenario
    @orchestrator = online_orchestrator
  end

  def claimed_input(check)
    job = Job.find(RuleCheckAttempt.where(rule_check_id: check.id).order(:attempt_number).last.job_id)
    assert_equal job.id, assert_completed(claim_job(@orchestrator)).result.fetch("job_id")
    [ Leverage::JobInputs.for(job.reload), job ]
  end

  test "a warn-only rule at ready to start hands the requested contract" do
    rule = model_rule(on_fail: "warn")
    task = scenario.task(state: "backlog", criteria: [])
    body = contract_body(title: "Requested made-up task", details: "Requested made-up details.")
    assert_completed(owner_command("complete_contract", body.merge("id" => task.id)))
    assert_equal "ready", task.reload.state, "a warn rule never blocks"
    check = RuleCheck.find_by!(task_id: task.id, rule_id: rule.id)

    input, job = claimed_input(check)

    contract = input.dig("material", "contract")
    assert_equal [ "Requested made-up task", "Requested made-up details." ],
      contract.values_at("title", "details")
    assert_equal [ "Made-up build criterion.", "A reviewer agrees." ], contract.fetch("criteria").map { |c| c["text"] }
    assert_equal job.input.fetch("inputs"), input.fetch("inputs")
    assert_equal check.input_hash, Leverage::Gating.input_hash(hook: "task.before_ready", inputs: input.fetch("inputs"))
  end

  test "a warn check claimed after a blocking check settled the submit keeps the handoff note" do
    model_rule(hook: "task.before_submit", name: "Made-up blocking rule")
    warn = model_rule(hook: "task.before_submit", on_fail: "warn", name: "Made-up warn rule")
    builder = scenario.seat(role: "builder")
    task = ready_to_submit(builder)
    assert_equal :pending, seat_command(builder, "submit", submit_body(task, note: "A made-up note to keep.")).outcome
    blocking = RuleCheck.where(task_id: task.id).where.not(rule_id: warn.id).sole
    warn_check = RuleCheck.find_by!(task_id: task.id, rule_id: warn.id)
    blocking_job = Job.find(RuleCheckAttempt.find_by!(rule_check_id: blocking.id).job_id)
    blocking_job.update_columns(queued_at: blocking_job.queued_at - 1)
    answer_next(@orchestrator, PASSED)
    assert_equal "in_review", task.reload.state
    assert_nil PendingTransition.find_by!(task_id: task.id).params, "the settled request is emptied (RE-2)"

    input, job = claimed_input(warn_check)

    assert_includes input.dig("material", "quoted"), { "label" => "handoff_note", "text" => "A made-up note to keep." }
    assert_equal job.input.fetch("inputs"), input.fetch("inputs")
    assert_equal warn_check.input_hash, Leverage::Gating.input_hash(hook: "task.before_submit", inputs: input.fetch("inputs"))
  end
end
