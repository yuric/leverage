require "test_helper"

class JobsAnyKindTest < ActiveSupport::TestCase
  setup do
    @scenario = Scenario.new
    @task = @scenario.task(state: "backlog")
  end

  test "a role is offered each kind it can claim, oldest first, and keeps the job it holds" do
    definitions = Leverage::Contract.jobs.fetch("jobs")
    definitions.group_by { |job| job.fetch("claimer_role") }.each do |role, kinds|
      seat = @scenario.seat(role: role)
      jobs = kinds.map.with_index do |definition, index|
        Leverage::Jobs.queue(@scenario.context(at: @scenario.context.at + index.seconds),
          kind: definition.fetch("kind"), task: @task, target: @task, seat_role: role, input: {})
      end
      # Use the last queue time, so all jobs are in the running for the offer.
      ctx = @scenario.context(at: jobs.last.queued_at)
      jobs.each do |job|
        assert_equal job, Leverage::Jobs.next_for(seat, at: ctx.at), job.kind
        assert_equal job.queued_at + ctx.workspace.check_queue_timeout_seconds, Leverage::Timers.job_due_at(job, :queue)
        assert_nil Leverage::Timers.job_due_at(job, :run)

        Leverage::Jobs.claim(ctx, job, seat)
        assert_equal job, Leverage::Jobs.next_for(seat, at: ctx.at)
        assert_equal job.claimed_at + ctx.workspace.check_run_timeout_seconds, Leverage::Timers.job_due_at(job, :run)
        Leverage::Jobs.finish(ctx, job, result: {}, tokens: 0, spend: 0)
      end
      assert_nil Leverage::Jobs.next_for(seat, at: ctx.at)
    end
  end

  test "an approval attempt uses its rule version's timeouts and the two check timers" do
    action = Action.create!(workspace_id: @task.workspace_id, task_id: @task.id, position: 1, kind: "send", state: "requested")
    rule = @scenario.rule(hook: "action.requested", queue_timeout_seconds: 71, run_timeout_seconds: 109)
    check = @scenario.rule_check(@task, rule: rule, subject: action, attempts: 0)
    request = Leverage::Transitions::Request.new(command: "request_action", workspace_id: @task.workspace_id,
      caller_kind: nil, caller_id: nil, key: nil, request_hash: nil, params: { "action_id" => action.id })
    ctx = @scenario.context(request: request)
    attempt = Leverage::RuleChecks.queue_attempt(ctx, check, kind: "approval")
    job = Job.find(attempt.job_id)
    queue_due = attempt.queued_at + 71

    assert_equal "check_queue_timeout", Leverage::Timers.job_timer_for(job)
    assert_equal queue_due, Leverage::Timers.job_due_at(job, :queue)
    assert_empty Leverage::Timers.due_jobs(@task.workspace_id, queue_due - 1.second, "check_queue_timeout", limit: 1)
    assert_equal [ job ], Leverage::Timers.due_jobs(@task.workspace_id, queue_due, "check_queue_timeout", limit: 1)

    seat = @scenario.orchestrator
    Leverage::Jobs.claim(ctx, job, seat)
    Leverage::RuleChecks.start(ctx, check, job: job, seat: seat)
    run_due = attempt.reload.started_at + 109

    assert_equal "check_run_timeout", Leverage::Timers.job_timer_for(job)
    assert_equal run_due, Leverage::Timers.job_due_at(job, :run)
    assert_equal [ job ], Leverage::Timers.due_jobs(@task.workspace_id, run_due, "check_run_timeout", limit: 1)

    # Advance the stored start time to put the run past its deadline.
    attempt.update!(started_at: ctx.at - 110.seconds)
    timeout = Leverage::Sweep.timer(@task.workspace_id, "check_run_timeout", "job_id" => job.id)

    assert_equal [ job.id ], timeout.result.fetch("timed_out_job_ids")
    retry_attempt = RuleCheckAttempt.find_by!(rule_check_id: check.id, attempt_number: attempt.attempt_number + 1)
    retry_job = Job.find(retry_attempt.job_id)
    assert_equal [ "approval", "queued" ], [ retry_job.kind, retry_job.state ]
    assert Leverage::Timers.second_miss?(retry_job)
  end
end
