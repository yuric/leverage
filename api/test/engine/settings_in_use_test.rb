require "test_helper"
require_relative "gate_support"

class SettingsInUseTest < ActiveSupport::TestCase
  include GateSupport

  setup do
    @scenario = Scenario.new(lease_length_seconds: 600, check_queue_timeout_seconds: 120,
      check_run_timeout_seconds: 300, maximum_rounds: 2, rerun_limit: 2)
    Leverage::Gating.implementation = Leverage::Rules::Engine.new
  end

  test "the command changes the length of the next lease without moving a running lease" do
    old_task = @scenario.task(state: "working")
    old_due = old_task.lease_due_at
    task = @scenario.task(state: "ready")
    builder = @scenario.seat

    change_settings("lease_length_seconds" => 900, "recovery_time_ceiling_seconds" => 600)
    assert command("claim", builder).completed?

    grant = mine(Event).find_by!(type: "task.claimed", task_id: task.id)
    assert_equal grant.at + 900, task.reload.lease_due_at
    assert_equal old_due, old_task.reload.lease_due_at
    assert_equal 600, Leverage::Reads::WorkspaceSettings.call(@scenario.workspace_id).fetch("recovery_time_ceiling_seconds")
  end

  test "changing the check timeouts moves both due times for jobs that are already waiting or running" do
    check_task = @scenario.task
    rule = custom_rule("task.before_ready")
    check = @scenario.rule_check(check_task, rule: rule)
    attempt = RuleCheckAttempt.find_by!(rule_check_id: check.id)
    queued = Job.find(attempt.job_id)
    running = @scenario.job(kind: "contract_draft", task: @scenario.task, state: "claimed", seat: @scenario.planner)

    change_settings("check_queue_timeout_seconds" => 180, "check_run_timeout_seconds" => 420)

    assert_at_new_deadline(queued, "check_queue_timeout", attempt.queued_at, 120, 180)
    assert_at_new_deadline(running, "contract_draft_job_run_timeout", running.claimed_at, 300, 420)
  end

  test "the next failed review uses the changed round limit" do
    task, review = ready_for_verdict(@scenario.seat, @scenario.seat(role: "reviewer"))
    reviewer = Seat.find(review.reviewer_seat_id)
    criterion = Criterion.find_by!(task_id: task.id, kind: "build")
    change_settings("maximum_rounds" => 1)

    assert command("fail_review", reviewer, pass_params(review).merge("verdict" => "failed",
      "failed_criteria" => [ criterion.id ])).completed?
    assert_equal [ "rounds_exceeded" ], Leverage::Holds.open_holds(task).map(&:reason)
  end

  test "the next changed input uses the new re-run limit" do
    rule = custom_rule("task.before_submit")
    builder = @scenario.seat
    orchestrator = @scenario.orchestrator
    task = ready_to_submit(builder)
    assert_equal :pending, command("submit", builder, submit_params(task)).outcome
    job_id = command("claim_job", orchestrator).result.fetch("job_id")
    assert command("submit_job_result", orchestrator, { "id" => job_id,
      "result" => { "result" => "failed", "reason" => "Sample reason" }, "tokens" => 0, "spend" => 0 }).completed?

    change_settings("rerun_limit" => 1)

    changed = command("submit", builder, submit_params(task, note: "Changed sample handoff."))
    assert_equal :pending, changed.outcome
    assert_equal [ "rerun_limit" ], Leverage::Holds.open_holds(task).map(&:reason)
    assert_equal 2, mine(RuleCheck).where(rule_id: rule.id).count
    assert_equal 1, mine(Job).where(task_id: task.id).count
  end

  private

  def change_settings(body)
    assert command("change_workspace_settings", @scenario.owner, body).completed?
  end

  def assert_at_new_deadline(job, timer, from, old_timeout, new_timeout)
    assert_empty Leverage::Timers.due_jobs(@scenario.workspace_id, from + old_timeout, timer, limit: 1)
    due = Leverage::Timers.due_jobs(@scenario.workspace_id, from + new_timeout, timer, limit: 1).sole
    assert_equal [ job.id, from + new_timeout ], [ due.id, due.timer_due_at ]
  end
end
