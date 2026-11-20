require "test_helper"
require_relative "job_timers_support"

# The check_queue_timeout timer (PRD L398, L399; timers.json;
# state_machine.json; milestone 4 plan WP7, TM-1, DB-31; traces 07 and 19):
# a rule check's attempt not claimed within its queue timeout is queued
# once more as a new attempt; a second miss gives the result error, and an
# error on a blocking rule leaves its transition pending under check_error
# (PendingTransitions.reenter, rule 9 of the plan's §2.1). Its events are
# the app's, with no key, effective at the due time: the attempt's queued
# time plus the rule version's own queue timeout, or the workspace's.
class CheckQueueTimeoutTest < ActiveSupport::TestCase
  include JobTimersSupport

  attr_reader :scenario

  setup { @scenario = Scenario.new }

  test "trace 07, command 4: a first miss times the job out, queues it again and queues a new attempt, at the due time" do
    _task, check, _pending = pending_check
    job = job_of(check)
    due = make_queue_due(check)
    before = last_seq

    outcome = nil
    calls = with_writers { outcome = timer("check_queue_timeout") }

    assert outcome.completed?
    assert_equal({ "timed_out_job_ids" => [ job.id ] }, outcome.result)
    assert_equal [ "Jobs.time_out", "Jobs.requeue", "RuleChecks.new_attempt" ], calls.map(&:name)
    assert_equal [ job.id, :queue ], [ calls.first.arguments.second.id, calls.first.arguments.third ]
    fresh = Job.where(target_id: check.id).order(:attempt_number).last
    assert_equal [ check.id, fresh.id ], [ calls.last.arguments.second.id, calls.last.keywords.fetch(:job).id ]
    timer_ctx = calls.first.arguments.first
    assert_equal [ nil, nil ], [ timer_ctx.request.caller_kind, timer_ctx.request.key ]
    assert_instant due, timer_ctx.effective_at

    events = events_after(before)
    assert_equal %w[job.timed_out job.requeued check.queued], events.map(&:type)
    assert_equal [ job.id, job.id, check.id ], events.map(&:subject_id)
    assert_equal [ 2, fresh.id ], [ events.last.payload["attempt_number"], events.last.payload["job_id"] ]
    assert_by_app_at events, due
    assert_instant due, fresh.queued_at, "the new attempt waits from the due time, so its own due time is 120 s on"
  end

  test "trace 07, command 5: a second miss ends the check in error and holds the task, with no task item while the orchestrator is offline" do
    orchestrator_polled(300)
    task, check, pending = pending_check(attempts: 2)
    job = job_of(check)
    due = make_queue_due(check)
    before = last_seq

    calls = with_writers { timer("check_queue_timeout") }

    assert_equal [ "Jobs.time_out", "RuleChecks.error", "PendingTransitions.reenter" ], calls.map(&:name)
    reenter = calls.last
    assert_equal pending.id, reenter.arguments.second.id
    assert_equal Leverage::Gating::Trigger.new(kind: :check_timed_out, rule_check_id: check.id), reenter.arguments.third
    events = events_after(before)
    assert_equal %w[job.timed_out check.finished hold.opened], events.map(&:type)
    assert_equal [ job.id, check.id ], events.first(2).map(&:subject_id)
    assert_equal "error", events.second.payload["result"]
    assert_equal events.second.id, events.third.cause_id
    assert_by_app_at events, due
    refute InboxItem.exists?(workspace_id: scenario.workspace_id, about_id: task.id), "SM-39"
  end

  test "with the orchestrator online the second miss opens the task's item as well (SM-39)" do
    orchestrator_polled(10)
    _task, check, _pending = pending_check(attempts: 2)
    due = make_queue_due(check)
    before = last_seq

    with_writers { timer("check_queue_timeout") }

    events = events_after(before)
    assert_equal %w[job.timed_out check.finished hold.opened inbox.opened], events.map(&:type)
    assert_by_app_at events, due
  end

  test "a miss of an attempt the owner ran again after an error is a first miss" do
    _task, check, = pending_check(attempts: 2)
    errored = job_of(check)
    errored.update!(state: "timed_out")
    check.update!(result: "error")
    rerun(check)
    due = make_queue_due(check)

    calls = with_writers { timer("check_queue_timeout") }

    assert_equal [ "Jobs.time_out", "Jobs.requeue", "RuleChecks.new_attempt" ], calls.map(&:name)
    assert_instant due, calls.first.arguments.first.effective_at
  end

  test "a miss of a withdrawn check's next attempt is a first miss (trace 18, command 13)" do
    _task, check, = pending_check
    withdrawn = job_of(check)
    withdrawn.update!(state: "withdrawn")
    scenario.append("job.withdrawn", task: Task.find(check.task_id), subject: withdrawn)
    rerun(check)
    make_queue_due(check)

    calls = with_writers { timer("check_queue_timeout") }

    assert_equal [ "Jobs.time_out", "Jobs.requeue", "RuleChecks.new_attempt" ], calls.map(&:name)
  end

  test "an error on a warn rule is recorded and holds nothing (L404)" do
    rule = scenario.rule(hook: "task.before_ready", on_fail: "warn")
    task = scenario.task(state: "backlog")
    check = scenario.rule_check(task, rule: rule, attempts: 2)
    due = make_queue_due(check)
    before = last_seq

    calls = with_writers { timer("check_queue_timeout") }

    assert_equal [ "Jobs.time_out", "RuleChecks.error" ], calls.map(&:name)
    assert_equal %w[job.timed_out check.finished], events_after(before).map(&:type)
    assert_by_app_at events_after(before), due
  end

  test "a rule version's own queue timeout wins over the workspace's" do
    own = scenario.rule(hook: "task.before_ready", queue_timeout_seconds: 30)
    _task, short, = pending_check(rule: own)
    _other, long, = pending_check(rule: scenario.rule(hook: "task.before_ready"))
    due = make_queue_due(short, timeout: 30)
    make_queue_due(long, timeout: 30)

    outcome = nil
    with_writers { outcome = timer("check_queue_timeout") }

    assert_equal [ job_of_attempt(short, 1).id ], timed_out(outcome),
      "the other check waits for the workspace's 120 seconds"
    assert_instant due, Event.where(type: "job.timed_out").sole.effective_at
  end

  test "an attempt not yet due, a claimed one and a finished one are left alone" do
    pending_check
    pending_check(started: true)
    _task, finished, = pending_check
    finished_job = job_of(finished)
    finished_job.update!(state: "finished")
    make_queue_due(finished)
    before = last_seq

    outcome = nil
    calls = with_writers { outcome = timer("check_queue_timeout") }

    assert_empty calls
    assert_equal({ "timed_out_job_ids" => [] }, outcome.result)
    assert_equal before, last_seq
  end

  test "the sweep's run takes at most its limit, oldest due first" do
    checks = 3.times.map { pending_check[1] }
    checks.each { |check| make_queue_due(check) }

    outcome = nil
    with_writers { outcome = timer("check_queue_timeout", "limit" => 2) }

    assert_equal checks.first(2).map { |check| job_of_attempt(check, 1).id }, timed_out(outcome)
  end

  test "a named job is timed out when it is due, and a named job that is not queued is invalid_state" do
    _task, check, = pending_check
    job = job_of(check)
    make_queue_due(check)

    outcome = nil
    with_writers { outcome = timer("check_queue_timeout", "job_id" => job.id) }
    assert_equal [ job.id ], timed_out(outcome)

    _other, claimed, = pending_check(started: true)
    refused = timer("check_queue_timeout", "job_id" => job_of(claimed).id)
    assert_equal "invalid_state", refused.refusal&.code
    draft = scenario.job(kind: "contract_draft", task: scenario.task(state: "backlog"))
    assert_equal "invalid_state", timer("check_queue_timeout", "job_id" => draft.id).refusal&.code,
      "a draft's job has timers of its own"
  end

  # The job of a check's attempt number n.
  def job_of_attempt(check, number) = Job.find(RuleCheckAttempt.find_by!(rule_check_id: check.id, attempt_number: number).job_id)

  # Run it again (WP8's rerun_check) as its rows leave a check: a new job,
  # queued by the owner, and its attempt (trace 19, command 20).
  def rerun(check)
    task = Task.find(check.task_id)
    number = RuleCheckAttempt.where(rule_check_id: check.id).maximum(:attempt_number) + 1
    job = scenario.job(kind: "rule_check", task: task, target: check, attempt_number: number)
    RuleCheckAttempt.create!(workspace_id: scenario.workspace_id, rule_check_id: check.id, attempt_number: number,
      job_id: job.id, queued_at: job.queued_at)
    check.update!(result: nil)
    job
  end
end
