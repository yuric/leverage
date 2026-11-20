require "test_helper"
require_relative "gate_support"

# RuleChecks, the only writer of rule_checks and rule_check_attempts and the
# only emitter of check.* (milestone 4 plan §2.1 rules 4 to 6, RE-1, RE-9;
# DB-25, DB-30, DB-31): an app check is one attempt and check.finished; a
# model check an attempt per job, check.queued before its job.queued, and
# check.started and check.finished as its job is claimed and answered; a
# re-run of the same identity is a new attempt of the same row. A reason
# stays on the row.
class RuleChecksTest < ActiveSupport::TestCase
  include GateSupport

  R = Leverage::RuleChecks

  setup do
    @scenario = Scenario.new
    @owner = @scenario.owner
    @task = @scenario.task(state: "backlog")
  end

  def in_command(**options)
    ActiveRecord::Base.transaction(requires_new: true) { yield @scenario.context(**options) }
  end

  def planned(rule, result:, checker: nil, input_hash: "a" * 64, reason: nil)
    version = @scenario.current_version(rule)
    Leverage::Gating::PlannedCheck.new(rule_id: rule.id, rule_version_id: version.id, hook: version.hook, round: @task.round,
      subject_kind: nil, subject_id: nil, input_hash: input_hash, checker: checker || version.checker, result: result,
      effect: nil, reason: reason)
  end

  def evaluation(checks, jobs: [])
    Leverage::Gating::Evaluation.new(outcome: :completed, frozen_rule_version_ids: [], checks: checks, jobs: jobs,
      failures: [], warnings: [], effects: [], holds_to_open: [])
  end

  def job_for(index) = Leverage::Gating::PlannedJob.new(kind: "rule_check", rule_check_ref: index, seat_role: "orchestrator")

  test "an app check is a row with its result and reason, one attempt queued, started and finished at once, and check.finished" do
    rule = app_rule("task.before_ready")
    rows, events, at = in_command do |ctx|
      [ R.write(ctx, evaluation([ planned(rule, result: "failed", reason: "Made-up reason.") ]), task: @task), ctx.events, ctx.at ]
    end

    check = rows.sole
    assert_equal [ "failed", "Made-up reason.", rule.id ], [ check.result, check.reason, check.rule_id ]
    attempt = RuleCheckAttempt.find_by!(rule_check_id: check.id)
    assert_equal [ 1, nil, at, at, at ], [ attempt.attempt_number, attempt.job_id, attempt.queued_at, attempt.started_at,
      attempt.finished_at ]
    event = events.sole
    assert_equal [ "check.finished", "rule_check", check.id ], [ event.type, event.subject_kind, event.subject_id ]
    assert_equal({ "hook" => "task.before_ready", "rule_id" => rule.id, "rule_version_id" => check.rule_version_id,
                   "result" => "failed", "effect" => nil, "wait_cause" => nil, "subject_kind" => nil, "subject_id" => nil,
                   "input_hash" => "a" * 64 }, event.payload)
    assert_not_includes event.payload.to_json, "Made-up reason", "a reason is content: never in a payload (RE-9)"
  end

  test "a model check is a row with no result, then its job: check.queued names the job and comes before job.queued" do
    rule = custom_rule("task.before_ready")
    pending = @scenario.pending_transition(@task, command: "complete_contract", requester: @owner)
    with_jobs do
      rows, events = in_command do |ctx|
        [ R.write(ctx, evaluation([ planned(rule, result: nil) ], jobs: [ job_for(0) ]), task: @task, pending: pending), ctx.events ]
      end

      check = rows.sole
      assert_nil check.result
      assert_equal %w[check.queued job.queued], events.map(&:type)
      job = Job.find(events.last.subject_id)
      assert_equal [ "rule_check", "orchestrator", "rule_check", check.id ], job.values_at(:kind, :seat_role, :target_kind, :target_id)
      assert_equal({ "rule_check_id" => check.id, "attempt_number" => 1, "rule_version_id" => check.rule_version_id,
                     "hook" => "task.before_ready", "task_id" => @task.id, "project_id" => nil },
        job.input.except("inputs"))
      queued = events.first.payload
      assert_equal [ 1, job.id, true, nil, pending.id, nil ],
        queued.values_at("attempt_number", "job_id", "blocking", "claimant_seat_id", "pending_transition_id", "action_id")
      assert_equal job.id, RuleCheckAttempt.find_by!(rule_check_id: check.id).job_id
    end
  end

  test "a model check the plan gives no job (past the re-run limit) is a row with no attempt and no event" do
    rule = custom_rule("task.before_ready")
    rows, events = in_command { |ctx| [ R.write(ctx, evaluation([ planned(rule, result: nil) ]), task: @task), ctx.events ] }

    assert_nil rows.sole.result
    assert_empty events
    assert_not RuleCheckAttempt.exists?(rule_check_id: rows.sole.id)
  end

  test "a re-run of the same identity is the same row, a new attempt, its result null until it finishes (DB-25)" do
    rule = custom_rule("task.before_ready")
    with_jobs do
      first = in_command { |ctx| R.write(ctx, evaluation([ planned(rule, result: nil) ], jobs: [ job_for(0) ]), task: @task).sole }
      in_command { |ctx| R.withdraw(ctx, first) }
      again, events = in_command do |ctx|
        [ R.write(ctx, evaluation([ planned(rule, result: nil) ], jobs: [ job_for(0) ]), task: @task).sole, ctx.events ]
      end

      assert_equal first.id, again.id
      assert_nil again.reload.result
      assert_equal [ 1, 2 ], RuleCheckAttempt.where(rule_check_id: first.id).order(:attempt_number).pluck(:attempt_number)
      assert_equal 2, events.first.payload["attempt_number"]
      assert_equal 2, Job.find(events.last.subject_id).input["attempt_number"]
    end
  end

  test "start, finish: the claiming seat starts the attempt, the result and reason go on the row, tokens and spend on the attempt" do
    rule = custom_rule("task.before_ready")
    orchestrator = @scenario.orchestrator
    with_jobs do
      check = in_command { |ctx| R.write(ctx, evaluation([ planned(rule, result: nil) ], jobs: [ job_for(0) ]), task: @task).sole }
      job = Job.find_by!(target_id: check.id)
      started, finished = in_command(request: seat_request(orchestrator)) do |ctx|
        [ R.start(ctx, check, job: job, seat: orchestrator),
          R.finish(ctx, check, result: "passed", reason: "Made-up reason.", tokens: 300, spend: 0.01) ]
      end

      assert_equal [ "check.started", "seat", orchestrator.id, { "attempt_number" => 1 } ],
        [ started.type, started.actor_kind, started.actor_id, started.payload ]
      assert_equal [ "check.finished", "passed" ], [ finished.type, finished.payload["result"] ]
      assert_equal [ "passed", "Made-up reason." ], check.reload.values_at(:result, :reason)
      attempt = RuleCheckAttempt.find_by!(rule_check_id: check.id)
      assert_equal [ orchestrator.id, 300, BigDecimal("0.01") ], attempt.values_at(:checker_seat_id, :tokens, :spend)
      assert attempt.started_at && attempt.finished_at
    end
  end

  test "error and withdraw end the check with that result; a timer's writes are the app's, with no key and its due time" do
    rule = custom_rule("task.before_ready")
    with_jobs do
      checks = in_command do |ctx|
        R.write(ctx, evaluation([ planned(rule, result: nil), planned(rule, result: nil, input_hash: "b" * 64) ],
          jobs: [ job_for(0), job_for(1) ]), task: @task)
      end
      due = @scenario.database_now - 30
      errored, withdrawn = in_command(request: seat_request(@scenario.orchestrator)) do |ctx|
        [ R.error(ctx, checks.first, actor_kind: "app", actor_id: nil, command_id: nil, effective_at: due),
          R.withdraw(ctx, checks.last) ]
      end

      assert_equal %w[error withdrawn], [ errored.payload["result"], withdrawn.payload["result"] ]
      assert_equal [ "app", nil, nil ], [ errored.actor_kind, errored.actor_id, errored.command_id ]
      assert_in_delta due, errored.effective_at, 0.001
      assert_equal "seat", withdrawn.actor_kind
      assert_equal %w[error withdrawn], checks.map { |check| check.reload.result }
    end
  end

  test "override records who, when and why on the row; check.overridden carries nothing of it" do
    rule = custom_rule("task.before_ready")
    check = @scenario.rule_check(@task, rule: rule, result: "failed", reason: "Made-up reason.")
    event, at = in_command(request: owner_request) do |ctx|
      [ R.override(ctx, check, user: @owner, reason: "Made-up override reason."), ctx.at ]
    end

    assert_equal [ "check.overridden", "owner", @owner.id, {} ], [ event.type, event.actor_kind, event.actor_id, event.payload ]
    assert_equal [ @owner.id, at, "Made-up override reason." ],
      check.reload.values_at(:overridden_by_user_id, :overridden_at, :override_reason)
    assert_equal "failed", check.result
  end

  test "queue_attempt queues the next attempt on a new job: check.queued names it, then job.queued, then the attempt row" do
    rule = custom_rule("task.before_ready")
    check = @scenario.rule_check(@task, rule: rule, result: "error")
    attempt, events = in_command { |ctx| [ R.queue_attempt(ctx, check), ctx.events ] }

    assert_equal %w[check.queued job.queued], events.map(&:type)
    job = Job.find(events.last.subject_id)
    assert_equal [ 2, job.id ], [ events.first.payload["attempt_number"], events.first.payload["job_id"] ]
    assert_equal [ 2, job.id ], attempt.values_at(:attempt_number, :job_id)
    assert_equal [ 2, check.id ], job.values_at(:attempt_number, :target_id)
    assert_nil check.reload.result
  end

  test "new_attempt queues the next attempt of a check on a job of its own" do
    rule = custom_rule("task.before_ready")
    check = @scenario.rule_check(@task, rule: rule)
    job = @scenario.job(kind: "rule_check", task: @task, target: check, attempt_number: 2)
    attempt, event = in_command { |ctx| [ R.new_attempt(ctx, check, job: job), ctx.events.last ] }

    assert_equal [ 2, job.id ], attempt.values_at(:attempt_number, :job_id)
    assert_equal [ "check.queued", 2, job.id ], [ event.type, event.payload["attempt_number"], event.payload["job_id"] ]
  end

  test "a claim check that fails lapses the provisional claim: its check.finished names the wait's cause" do
    rule = custom_rule("task.before_claim")
    builder = @scenario.seat(role: "builder", credential: @scenario.credential)
    task = @scenario.task(state: "ready")
    pending = @scenario.pending_transition(task, command: "claim", requester: builder)
    check = @scenario.rule_check(task, rule: rule, subject: builder, pending: pending, started: true)
    calls = spy_on(Leverage::Candidates, :wait_cause) do
      in_command { |ctx| R.finish(ctx, check, result: "failed", reason: "Made-up reason.") }
    end

    assert_equal [ task.id ], calls.map { |call| call.arguments.first.id }
  end

  test "unknown event keywords are refused" do
    rule = custom_rule("task.before_ready")
    check = @scenario.rule_check(@task, rule: rule)
    in_command do |ctx|
      assert_raises(ArgumentError) { R.withdraw(ctx, check, cause: "made-up") }
    end
  end

  private

  def seat_request(seat)
    T::Request.new(command: "claim_job", workspace_id: @scenario.workspace_id, caller_kind: "seat", caller_id: seat.id,
      key: "k-#{SecureRandom.hex(4)}", request_hash: nil, params: {})
  end

  def owner_request
    T::Request.new(command: "override_check", workspace_id: @scenario.workspace_id, caller_kind: "owner", caller_id: @owner.id,
      key: "k-#{SecureRandom.hex(4)}", request_hash: nil, params: {})
  end
end
