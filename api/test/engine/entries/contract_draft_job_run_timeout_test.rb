require "test_helper"
require_relative "job_timers_support"

# The contract_draft_job_run_timeout timer (timers.json; state_machine.json;
# milestone 4 plan WP7, RD-37, DB-31): a draft job claimed by a planner and
# not finished within the workspace's check run timeout is queued once
# more; a second miss ends it and the task stays in Backlog. No item opens
# for a planner (RD-20).
class ContractDraftJobRunTimeoutTest < ActiveSupport::TestCase
  include JobTimersSupport

  attr_reader :scenario

  setup { @scenario = Scenario.new }

  def claimed_draft(attempt_number: 1)
    scenario.job(kind: "contract_draft", task: scenario.task(state: "backlog"), state: "claimed", seat: scenario.planner,
      attempt_number: attempt_number)
  end

  test "a first miss times the claimed draft out and queues it once more, at the claim plus the run timeout" do
    scenario.workspace.update!(check_run_timeout_seconds: 200)
    job = claimed_draft
    due = make_job_due(job, :run, timeout: 200)
    before = last_seq

    outcome = nil
    calls = with_writers { outcome = timer("contract_draft_job_run_timeout") }

    assert_equal({ "timed_out_job_ids" => [ job.id ] }, outcome.result)
    assert_equal [ "Jobs.time_out", "Jobs.requeue" ], calls.map(&:name)
    assert_equal :run, calls.first.arguments.third
    events = events_after(before)
    assert_equal %w[job.timed_out job.requeued], events.map(&:type)
    assert_by_app_at events, due
  end

  test "a second miss ends the draft, and no item opens for the planner (RD-20)" do
    job = claimed_draft(attempt_number: 2)
    due = make_job_due(job, :run)
    before = last_seq

    calls = with_writers { timer("contract_draft_job_run_timeout") }

    assert_equal [ "Jobs.time_out" ], calls.map(&:name)
    assert_equal %w[job.timed_out], events_after(before).map(&:type)
    assert_by_app_at events_after(before), due
    assert_equal "backlog", Task.find(job.task_id).state
    refute InboxItem.exists?(workspace_id: scenario.workspace_id)
  end

  test "a claimed draft not yet due is left alone" do
    claimed_draft
    before = last_seq

    assert_empty(with_writers { timer("contract_draft_job_run_timeout") })
    assert_equal before, last_seq
  end
end
