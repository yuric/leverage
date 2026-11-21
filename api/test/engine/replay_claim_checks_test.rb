require "test_helper"
require_relative "../support/walk"
require_relative "entries/jobs_support"

# A claim waits on two model checks (two rules at "before an agent starts
# it") and one fails while the other still runs. The engine keeps the claim
# pending until the other has a result and then refuses it with every
# failure (Rules::Reentry, steps 3 and 6), so the claimant holds the Ready
# task until then. Replay must say the same: the provisional claim lapses
# when no check of it is still running and one of them failed or erred, or
# when every one was withdrawn (DB-43). Walk 44727 of the step partition
# test found replay clearing the holder at the first failure while the
# table kept it (milestone 4 WP20, the whole suite with SEED=44444).
class ReplayClaimChecksTest < ActiveSupport::TestCase
  include JobsSupport

  test "a failed blocking check leaves the provisional holder until the other blocking check finishes" do
    use_scenario
    blocking = model_rule(hook: "task.before_claim", name: "Made-up first blocking rule")
    model_rule(hook: "task.before_claim", name: "Made-up second blocking rule")
    orchestrators = Array.new(2) { scenario.orchestrator(credential: scenario.credential(provider: "codex", model: nil), model: "m") }
    builder = scenario.seat(role: "builder", credential: scenario.credential)
    task = scenario.task(state: "ready")
    start = scenario.workspace.reload.last_seq

    assert_equal :pending, seat_command(builder, "claim").outcome
    jobs = orchestrators.to_h { |seat| [ seat, Job.find(assert_completed(claim_job(seat)).result.fetch("job_id")) ] }
    first, second = jobs.partition { |_, job| RuleCheck.find(job.target_id).rule_id == blocking.id }
    assert_equal 1, first.size
    assert_equal 1, second.size
    first_seat, first_job = first.first
    second_seat, second_job = second.first

    assert_completed(submit_result(first_seat, first_job, { "result" => "failed", "reason" => "A made-up reason." }))
    assert_equal builder.id, task.reload.holder_seat_id
    assert_equal "claimed", second_job.reload.state
    assert_empty Leverage::Replay.diff(scenario.workspace_id)
    assert_empty Leverage::LogAudit.call(scenario.workspace_id, after_seq: start)

    assert_completed(submit_result(second_seat, second_job, { "result" => "passed", "reason" => "A made-up reason." }))
    assert_nil task.reload.holder_seat_id
    assert_empty Leverage::Replay.diff(scenario.workspace_id)
    assert_empty Leverage::LogAudit.call(scenario.workspace_id, after_seq: start)
  end

  test "walk 44727 is replayable and passes the log audit" do
    walk = Walk.new(seed: 44_727, steps: 100).run
    assert_empty Leverage::Replay.diff(walk.workspace_id), walk.to_s
    assert_empty Leverage::LogAudit.call(walk.workspace_id), walk.to_s
  end
end

# The engine keeps a pending claim only for its blocking checks
# (Rules::Reentry, step 3: a warn rule never blocks, RC-16): when a
# blocking check fails while a warn rule's check still runs, the claim is
# refused at once and the claimant no longer holds the Ready task. Replay
# must not wait for the warn rule's check (DB-43). Walk 534 (seed 535) took
# this path under a clock that stepped back (ClockStepBackTest's).
class ReplayClaimWarnCheckTest < ActiveSupport::TestCase
  include JobsSupport

  FAILED = { "result" => "failed", "reason" => "The note does not name the tests." }.freeze

  test "a claim whose blocking check fails while a warn rule's check runs replays as the table holds it" do
    use_scenario
    blocking = model_rule(hook: "task.before_claim", name: "Made-up blocking rule")
    model_rule(hook: "task.before_claim", on_fail: "warn", name: "Made-up warn rule")
    orchestrators = Array.new(2) { scenario.orchestrator(credential: scenario.credential(provider: "codex", model: nil), model: "m") }
    builder = scenario.seat(role: "builder", credential: scenario.credential)
    task = scenario.task(state: "ready")
    start = scenario.workspace.reload.last_seq

    assert_equal :pending, seat_command(builder, "claim").outcome
    jobs = orchestrators.to_h { |seat| [ seat, Job.find(assert_completed(claim_job(seat)).result.fetch("job_id")) ] }
    seat, job = jobs.find { |_, each| RuleCheck.find(RuleCheckAttempt.find_by!(job_id: each.id).rule_check_id).rule_id == blocking.id }
    assert_completed(submit_result(seat, job, FAILED))

    assert_nil task.reload.holder_seat_id, "the engine refused the claim at the blocking failure"
    assert_empty Leverage::Replay.diff(scenario.workspace_id)
    assert_empty Leverage::LogAudit.call(scenario.workspace_id, after_seq: start)
  end
end
