require_relative "jobs_support"

# What the tests of the adversarial review's engine findings share
# (milestone 4, Review fixes): whole gated moves through the real
# pipeline and the real engine, as the agents and the owner send them.
# A builder's submit and a reviewer's pass wait on a model check that the
# orchestrator claims and answers; the timers run as the sweep runs them.
# Every value is made up.
module GatedFlowSupport
  include JobsSupport

  FAILED = { "result" => "failed", "reason" => "The made-up note names no test." }.freeze
  PASSED = { "result" => "passed", "reason" => "The made-up note names the tests." }.freeze

  # An orchestrator on a login of its own that has just polled.
  def online_orchestrator
    seat = scenario.orchestrator(credential: scenario.credential(provider: "codex", model: nil), model: "codex-model-1")
    seat.update_columns(last_polled_at: scenario.database_now)
    seat
  end

  # Acknowledges the task's current briefing as its builder.
  def acknowledge(builder, task)
    assert_completed(seat_command(builder, "acknowledge_briefing", { "id" => task.id,
      "briefing_hash" => Leverage::Briefing.hash_for(task.reload, seat: builder) }))
  end

  # A Working task held by builder, its briefing acknowledged and every
  # build criterion passed with evidence: ready to submit.
  def ready_to_submit(builder)
    task = scenario.task(state: "working", builder: builder)
    acknowledge(builder, task)
    Criterion.where(task_id: task.id, kind: "build").each do |criterion|
      assert_completed(seat_command(builder, "pass_criterion", { "id" => task.id, "cid" => criterion.id,
        "evidence" => { "kind" => "link", "value" => "https://example.test/made-up-proof" } }))
    end
    task.reload
  end

  def submit_body(task, note: "A made-up handoff note.")
    { "id" => task.id, "handoff_note" => note, "work_reference" => nil }
  end

  # An In review task whose review reviewer holds, the review briefing
  # acknowledged: ready for a verdict. Returns [task, review].
  def ready_for_verdict(reviewer)
    task = scenario.task(state: "in_review")
    review = scenario.review(task, reviewer: reviewer)
    assert_completed(seat_command(reviewer, "acknowledge_review_briefing", { "id" => review.id,
      "briefing_hash" => Leverage::Briefing.hash_for(task, seat: reviewer, review: review) }))
    [ task.reload, review.reload ]
  end

  def pass_body(review)
    { "id" => review.id, "verdict" => "passed", "failed_criteria" => [], "notes" => "Made-up notes.", "tokens" => 10,
      "spend" => 0 }
  end

  # The orchestrator claims the next job and answers it. Returns the job.
  def answer_next(orchestrator, result)
    claimed = assert_completed(claim_job(orchestrator))
    job = Job.find(claimed.result.fetch("job_id"))
    assert_completed(submit_result(orchestrator, job, result))
    job
  end

  # The commands row of a caller's key.
  def command_row(caller, key)
    Command.find_by!(caller_kind: caller.is_a?(Seat) ? "seat" : "owner", caller_id: caller.id, key: key)
  end

  # A timer, as the sweep runs it: by the app, no key, no commands row.
  def timer(command, params = {})
    T.apply(T::Request.new(command: command, workspace_id: scenario.workspace_id, caller_kind: nil, caller_id: nil, key: nil,
      request_hash: nil, params: params))
  end

  # The latest attempt of a check.
  def latest_attempt(check) = RuleCheckAttempt.where(rule_check_id: check.id).order(:attempt_number).last

  # Misses the queue timeout of the check's latest attempt once: its job
  # was queued a queue timeout before the database's now.
  def miss_queue(check, timeout: 120)
    due = scenario.database_now
    attempt = latest_attempt(check)
    attempt.update_columns(queued_at: due - timeout)
    Job.where(id: attempt.job_id).update_all(queued_at: due - timeout)
    timer("check_queue_timeout")
  end

  # Two missed queue timeouts: the check ends in error (L399).
  def error_check(check)
    2.times { miss_queue(check) }
    assert_equal "error", check.reload.result
  end

  def open_holds(task) = Hold.where(workspace_id: task.workspace_id, task_id: task.id, closed_at: nil).to_a

  def open_items(task)
    InboxItem.where(workspace_id: task.workspace_id, about_kind: "task", about_id: task.id, state: "open").to_a
  end
end
