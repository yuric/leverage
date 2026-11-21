require "test_helper"
require_relative "job_timers_support"

# The contract_draft_job_queue_timeout timer (timers.json;
# state_machine.json; milestone 4 plan WP7, RD-37, DB-31): a draft job not
# claimed within the workspace's check queue timeout is queued once more;
# a second miss ends it and the task stays in Backlog. A draft's job is the
# attempt itself, so the job's own attempt_number says which miss it is
# (the plan's §2.3, the jobs.attempt_number column).
class ContractDraftJobQueueTimeoutTest < ActiveSupport::TestCase
  include JobTimersSupport

  attr_reader :scenario

  setup { @scenario = Scenario.new }

  def draft(attempt_number: 1)
    scenario.job(kind: "contract_draft", task: scenario.task(state: "backlog"), attempt_number: attempt_number)
  end

  test "a first miss times the draft's job out and queues it once more, at the due time" do
    job = draft
    due = make_job_due(job, :queue)
    before = last_seq

    outcome = nil
    calls = with_writers { outcome = timer("contract_draft_job_queue_timeout") }

    assert_equal({ "timed_out_job_ids" => [ job.id ] }, outcome.result)
    assert_equal [ "Jobs.time_out", "Jobs.requeue" ], calls.map(&:name)
    assert_equal [ job.id, :queue ], [ calls.first.arguments.second.id, calls.first.arguments.third ]
    events = events_after(before)
    assert_equal %w[job.timed_out job.requeued], events.map(&:type)
    assert_by_app_at events, due
    assert_equal 2, Job.where(target_id: job.target_id).maximum(:attempt_number)
  end

  test "a second miss ends the draft: the job times out, nothing is queued and the task stays in Backlog" do
    job = draft(attempt_number: 2)
    due = make_job_due(job, :queue)
    before = last_seq

    calls = with_writers { timer("contract_draft_job_queue_timeout") }

    assert_equal [ "Jobs.time_out" ], calls.map(&:name)
    events = events_after(before)
    assert_equal %w[job.timed_out], events.map(&:type)
    assert_by_app_at events, due
    assert_equal "backlog", Task.find(job.task_id).state
  end

  test "a draft not yet due, or already claimed, is left alone; a check's job is not a draft's" do
    draft
    claimed = draft
    claimed.update_columns(state: "claimed", claimed_at: scenario.database_now, claimed_by_seat_id: scenario.planner.id)
    make_job_due(claimed, :queue)
    check = scenario.rule_check(scenario.task(state: "backlog"), rule: scenario.rule(hook: "task.before_ready"))
    make_queue_due(check)
    before = last_seq

    calls = with_writers { timer("contract_draft_job_queue_timeout") }

    assert_empty calls
    assert_equal before, last_seq
  end
end
