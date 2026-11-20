require "test_helper"
require_relative "job_timers_support"

# The check_run_timeout timer (PRD L399; timers.json; state_machine.json;
# milestone 4 plan WP7, TM-1; trace 19, commands 17 and 19): a rule
# check's attempt claimed but not finished within its run timeout is
# queued once more as a new attempt; a second miss gives the result error.
# Due at the attempt's start plus the rule version's own run timeout, or the
# workspace's.
class CheckRunTimeoutTest < ActiveSupport::TestCase
  include JobTimersSupport

  attr_reader :scenario

  setup { @scenario = Scenario.new }

  test "trace 19, command 17: a first miss of a started attempt queues it once more, at the due time" do
    orchestrator = orchestrator_polled(10)
    _task, check, = pending_check(started: true, checker: orchestrator)
    job = job_of(check)
    due = make_run_due(check)
    before = last_seq

    outcome = nil
    calls = with_writers { outcome = timer("check_run_timeout") }

    assert_equal({ "timed_out_job_ids" => [ job.id ] }, outcome.result)
    assert_equal [ "Jobs.time_out", "Jobs.requeue", "RuleChecks.new_attempt" ], calls.map(&:name)
    assert_equal :run, calls.first.arguments.third
    events = events_after(before)
    assert_equal %w[job.timed_out job.requeued check.queued], events.map(&:type)
    assert_by_app_at events, due
  end

  test "trace 19, command 19: a second miss with the orchestrator online holds the task and opens its item" do
    orchestrator = orchestrator_polled(10)
    task, check, pending = pending_check(attempts: 2, started: true, checker: orchestrator)
    due = make_run_due(check)
    before = last_seq

    calls = with_writers { timer("check_run_timeout") }

    assert_equal [ "Jobs.time_out", "RuleChecks.error", "PendingTransitions.reenter" ], calls.map(&:name)
    assert_equal [ pending.id, :check_timed_out ], [ calls.last.arguments.second.id, calls.last.arguments.third.kind ]
    events = events_after(before)
    assert_equal %w[job.timed_out check.finished hold.opened inbox.opened], events.map(&:type)
    assert_by_app_at events, due
    assert_equal task.id, events.last.task_id
  end

  test "a rule version's own run timeout wins over the workspace's" do
    orchestrator = orchestrator_polled(10)
    own = scenario.rule(hook: "task.before_ready", run_timeout_seconds: 45)
    _task, short, = pending_check(rule: own, started: true, checker: orchestrator)
    _other, long, = pending_check(rule: scenario.rule(hook: "task.before_ready"), started: true,
      checker: scenario.orchestrator)
    due = make_run_due(short, timeout: 45)
    make_run_due(long, timeout: 45)

    outcome = nil
    with_writers { outcome = timer("check_run_timeout") }

    assert_equal [ job_of(short).id ], timed_out(outcome)
    assert_instant due, Event.where(workspace_id: scenario.workspace_id, type: "job.timed_out").sole.effective_at
  end

  test "a queued attempt has no run due time, and a started one not yet due is left alone" do
    _task, queued, = pending_check
    make_queue_due(queued)
    pending_check(started: true)
    before = last_seq

    calls = with_writers { timer("check_run_timeout") }

    assert_empty calls, "the queue timer is check_queue_timeout's"
    assert_equal before, last_seq
  end

  test "a named job that is not claimed is invalid_state" do
    _task, check, = pending_check

    assert_equal "invalid_state", timer("check_run_timeout", "job_id" => job_of(check).id).refusal&.code
  end
end
