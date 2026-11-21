require "test_helper"
require_relative "entries/jobs_support"

# AE-14: the existing consumers use workspace settings at the time of use.
class SettingsFromRowTest < ActiveSupport::TestCase
  include JobsSupport

  setup { use_scenario }

  test "a changed lease length applies to the next claim even when the clock steps back" do
    scenario.workspace.update!(lease_length_seconds: 600)
    first = scenario.task(state: "ready")
    first_claim = claim_task
    assert_equal first_claim.at + 600, first.reload.lease_due_at

    scenario.workspace.update!(lease_length_seconds: 900)
    second = scenario.task(state: "ready")
    second_claim = nil
    answering(Leverage::WorkspaceLock, :clock, -> { first_claim.at - 1 }) { second_claim = claim_task }

    assert_operator second_claim.at, :>, first_claim.at
    assert_equal second_claim.at + 900, second.reload.lease_due_at
    assert_equal first_claim.at + 600, first.reload.lease_due_at
  end

  test "a changed queue timeout applies to a queued rule check and contract draft" do
    scenario.workspace.update!(check_queue_timeout_seconds: 120)
    check_job, draft_job = jobs_in("queued")
    timers = { "check_queue_timeout" => check_job, "contract_draft_job_queue_timeout" => draft_job }
    assert_timeouts(timers, :queue, :queued_at, before: 120, after: 180) do
      scenario.workspace.update!(check_queue_timeout_seconds: 180)
    end
  end

  test "a changed run timeout applies to a claimed rule check and contract draft" do
    scenario.workspace.update!(check_run_timeout_seconds: 300)
    check_job, draft_job = jobs_in("claimed")
    timers = { "check_run_timeout" => check_job, "contract_draft_job_run_timeout" => draft_job }
    assert_timeouts(timers, :run, :claimed_at, before: 300, after: 420) do
      scenario.workspace.update!(check_run_timeout_seconds: 420)
    end
  end

  test "a changed maximum applies to the next failed review" do
    scenario.workspace.update!(maximum_rounds: 2)
    assert_nil open_hold(fail_a_review)

    scenario.workspace.update!(maximum_rounds: 1)
    assert_equal "rounds_exceeded", open_hold(fail_a_review)&.reason
  end

  test "a changed rerun limit applies when checking the same task's next input" do
    scenario.workspace.update!(rerun_limit: 2)
    task = scenario.task
    rule = model_rule
    scenario.rule_check(task, rule: rule, input_hash: "a" * 64)
    fields = { task: task, rule_id: rule.id, hook: scenario.current_version(rule).hook, round: task.round,
               subject_kind: nil, subject_id: nil, input_hash: "b" * 64 }

    refute Leverage::Rules::RerunLimit.reached?(**fields)
    scenario.workspace.update!(rerun_limit: 1)
    assert Leverage::Rules::RerunLimit.reached?(**fields)
  end

  private

  def claim_task
    builder = scenario.seat(role: "builder")
    events_written { assert_completed(seat_command(builder, "claim")) }.find { |event| event.type == "task.claimed" }
  end

  def jobs_in(state)
    claimed = state == "claimed"
    task = scenario.task
    check = scenario.rule_check(task, rule: model_rule, started: claimed)
    draft = scenario.job(kind: "contract_draft", task: scenario.task, state: state,
      seat: (scenario.planner(provider: "claude") if claimed))
    [ job_of(check), draft ]
  end

  def assert_timeouts(timers, phase, start_column, before:, after:)
    timers.each_value do |job|
      assert_equal job.public_send(start_column) + before, Leverage::Timers.job_due_at(job, phase)
    end
    yield
    timers.each do |timer, job|
      now = job.public_send(start_column) + before
      assert_equal job.public_send(start_column) + after, Leverage::Timers.job_due_at(job, phase)
      assert_empty Leverage::Timers.due_jobs(scenario.workspace_id, now, timer, limit: 1)
      due = Leverage::Timers.due_jobs(scenario.workspace_id, job.public_send(start_column) + after, timer, limit: 1).sole
      assert_equal [ job.id, job.public_send(start_column) + after ], [ due.id, due.timer_due_at ]
    end
  end

  def fail_a_review
    builder = scenario.seat(role: "builder")
    reviewer = scenario.seat(role: "reviewer")
    task = scenario.task(state: "in_review", builder: builder)
    review = scenario.review(task, reviewer: reviewer)
    hash = Leverage::Briefing.hash_for(task, seat: reviewer, review: review)
    assert_completed(seat_command(reviewer, "acknowledge_review_briefing", { "id" => review.id, "briefing_hash" => hash }))
    criterion = Criterion.find_by!(task_id: task.id, kind: "build")
    assert_completed(seat_command(reviewer, "fail_review", { "id" => review.id, "verdict" => "failed",
      "failed_criteria" => [ criterion.id ], "notes" => "", "tokens" => 0, "spend" => 0 }))
    task
  end
end
