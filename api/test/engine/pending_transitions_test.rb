require "test_helper"
require_relative "gate_support"
require_relative "../support/trace_runner"

# A pending transition's life (PRD L374-L384; milestone 4 plan §2.1 rules
# 9 and 11, RE-2 to RE-6, RD-10, RD-13, SM-6, SM-14): stored whole when a
# blocking model check applies, then completed, refused or cancelled inside
# another command, as its requester. Against Gating::StandIn worlds
# (GateSupport::RowGating) and the stub Jobs (GateSupport#with_jobs); the
# commands that bring results (WP6, WP7, WP8) are not here, so the test
# calls PendingTransitions.reenter itself, as they will.
class PendingTransitionsTest < ActiveSupport::TestCase
  include GateSupport

  P = Leverage::PendingTransitions
  TRACE_07 = "07-pending-gate-check-error-override".freeze

  setup do
    @scenario = Scenario.new
    @owner = @scenario.owner
    @builder = @scenario.seat(role: "builder", credential: @scenario.credential)
    @reviewer = @scenario.seat(role: "reviewer", credential: @scenario.credential(provider: "codex"))
  end

  def trigger(kind, check = nil) = Leverage::Gating::Trigger.new(kind: kind, rule_check_id: check&.id)

  # Runs block inside one transaction holding the workspace lock, as a
  # command of the app does: what WP6's job result or WP8's override do
  # before they call reenter.
  def in_command(**options)
    ActiveRecord::Base.transaction(requires_new: true) { yield @scenario.context(**options) }
  end

  # A pending submit: the builder's submit met a blocking model gate.
  def pending_submit(rule = custom_rule("task.before_submit"))
    gating(rule)
    task = ready_to_submit(@builder)
    outcome = command("submit", @builder, submit_params(task))
    assert_equal :pending, outcome.outcome
    [ task.reload, P.of(task), RuleCheck.find_by!(rule_id: rule.id, task_id: task.id), @key ]
  end

  # --- trace 07, its first two commands ----------------------------------------------

  test "trace 07's first two commands, event for event: Complete contract writes the app check, waits on the model check and queues its job" do
    trace = Leverage::Contract.trace(TRACE_07).deep_dup
    binder = Leverage::Contract::TraceBinder.new(start: Time.utc(2026, 1, 1))
    complete = trace.fetch("commands")[1]
    params = binder.bind(complete.fetch("body"))
    # The trace's two digests are made up and differ for one set of inputs
    # (notes, WP1 and WP0T): both checks carry the one real hash.
    real = Leverage::Gating.input_hash(hook: "task.before_ready",
      inputs: Leverage::HookInputs.for(hook: "task.before_ready", task: nil, params: params))
    complete.dig("expect", "events").each { |event| event["payload"]["input_hash"] = real if event["payload"].key?("input_hash") }
    world = %w[acceptance_criteria specific_details].map do |key|
      { id: binder.id("$rule:#{key}"), version_id: binder.id("$rule_version:#{key}_1"), version: 1, hook: "task.before_ready",
        kind: "gate", checker: key == "specific_details" ? "model" : "app", on_fail: "block", route: "owner", enabled: true,
        scope: "covers" }
    end
    Leverage::Gating.implementation = Leverage::Gating::StandIn.new(rules: world)

    runner = nil
    with_jobs { runner = TraceRunner.new(TRACE_07, trace: trace).run(2) }

    assert_empty runner.failures
    pending = PendingTransition.where(workspace_id: runner.workspace_id).sole
    assert_equal [ "complete_contract", "owner", binder.id("$user:owner"), binder.id("$key:t1_complete"),
                   params.merge("id" => pending.task_id) ],
      [ pending.command, pending.requester_kind, pending.requester_id, pending.command_key, pending.params ]
    assert_equal world.map { |rule| rule[:version_id] }, pending.frozen_rule_version_ids
  end

  test "trace 07's re-entry: the overridden error completes the stored Complete contract as the owner, with its key, caused by the check's check.finished" do
    rule = custom_rule("task.before_ready", route: "owner")
    gating(rule)
    task = @scenario.task(state: "backlog")
    params = contract_params(task)
    pending = @scenario.pending_transition(task, command: "complete_contract", requester: @owner, key: "k-complete",
      params: params, frozen_rule_version_ids: [ @scenario.current_version(rule).id ])
    row = Command.create!(workspace_id: @scenario.workspace_id, caller_kind: "owner", caller_id: @owner.id, key: "k-complete",
      command: "complete_contract", request_hash: "made-up", outcome: "pending", pending_transition_id: pending.id)
    check = @scenario.rule_check(task, rule: rule, result: "error", pending: pending, attempts: 2)
    errored = Leverage::RuleChecks.last_finished(check)

    events = in_command do |ctx|
      overridden = Leverage::RuleChecks.override(ctx, check, user: @owner, reason: "Made-up reason.")
      P.reenter(ctx, pending, trigger(:check_overridden, check))
      ctx.events.drop_while { |event| event.id != overridden.id }.drop(1)
    end

    assert_equal %w[task.contract_changed task.ready], events.map(&:type)
    events.each do |event|
      assert_equal [ "owner", @owner.id, "k-complete", errored.id ], [ event.actor_kind, event.actor_id, event.command_id, event.cause_id ]
    end
    assert_equal [ "ready", 1 ], task.reload.values_at(:state, :contract_version)
    assert_equal [ "completed", nil ], pending.reload.values_at(:state, :params)
    row.reload
    assert_equal [ "completed", true, nil ], [ row.outcome, row.notify, row.refusal ]
  end

  # --- completing, refusing ----------------------------------------------------------

  test "a pending submit completes as the builder when its check passes, with its key and the check.finished as cause, and its request is emptied" do
    with_jobs do
      task, pending, check, key = pending_submit
      assert_equal submit_params(task), pending.params
      finished = in_command do |ctx|
        event = Leverage::RuleChecks.finish(ctx, check, result: "passed", reason: "Made-up reason.")
        P.reenter(ctx, pending, trigger(:check_finished, check))
        event
      end

      submitted = Event.find_by!(task_id: task.id, type: "task.submitted")
      assert_equal [ "seat", @builder.id, key, finished.id ], [ submitted.actor_kind, submitted.actor_id, submitted.command_id,
        submitted.cause_id ]
      assert_equal "in_review", task.reload.state
      assert_equal [ "completed", nil ], pending.reload.values_at(:state, :params)
      assert_equal [ "completed", true ], Command.find_by!(key: key).values_at(:outcome, :notify)
    end
  end

  test "a failed check refuses the pending submit blocked_by_rule with the rule and its reason, and the builder keeps the task" do
    with_jobs do
      rule = custom_rule("task.before_submit")
      task, pending, check, key = pending_submit(rule)
      in_command do |ctx|
        Leverage::RuleChecks.finish(ctx, check, result: "failed", reason: "The note names no test.")
        P.reenter(ctx, pending, trigger(:check_finished, check))
      end

      row = Command.find_by!(key: key)
      assert_equal [ "refused", true ], [ row.outcome, row.notify ]
      assert_equal({ "code" => "blocked_by_rule", "rule_id" => rule.id, "reason" => "The note names no test." }, row.refusal)
      assert_equal [ "refused", nil ], pending.reload.values_at(:state, :params)
      assert_equal [ "working", @builder.id ], task.reload.values_at(:state, :holder_seat_id)
      assert_empty written(key).drop(2), "the refusal writes no event of the submit's"
    end
  end

  test "a failed check at ready to start completes the owner's Complete contract with its contract change and a contract_incomplete hold (trace 16, RD-10)" do
    with_jobs do
      rule = custom_rule("task.before_ready", route: "owner")
      gating(rule)
      task = @scenario.task(state: "backlog")
      assert_equal :pending, command("complete_contract", @owner, contract_params(task)).outcome
      key = @key
      pending = P.of(task)
      check = RuleCheck.find_by!(rule_id: rule.id)
      finished = in_command do |ctx|
        event = Leverage::RuleChecks.finish(ctx, check, result: "failed", reason: "Made-up reason.")
        P.reenter(ctx, pending, trigger(:check_finished, check))
        event
      end

      later = written(key).drop(2)
      assert_equal %w[task.contract_changed hold.opened], later.map(&:type)
      later.each { |event| assert_equal [ "owner", @owner.id, finished.id ], [ event.actor_kind, event.actor_id, event.cause_id ] }
      assert_equal [ "backlog", 1 ], task.reload.values_at(:state, :contract_version)
      assert_equal "completed", Command.find_by!(key: key).outcome
      assert mine(Hold).exists?(task_id: task.id, reason: "contract_incomplete", rule_check_id: check.id, closed_at: nil)
    end
  end

  test "a failed check at when the review has passed is a failed review in full: fail_review's events as the reviewer, failed_rule_check_id, no review.passed" do
    with_jobs do
      rule = custom_rule("task.before_done")
      gating(rule)
      task, review = ready_for_verdict(@builder, @reviewer)
      assert_equal :pending, command("pass_review", @reviewer, pass_params(review)).outcome
      key = @key
      check = RuleCheck.find_by!(rule_id: rule.id)
      finished = in_command do |ctx|
        event = Leverage::RuleChecks.finish(ctx, check, result: "failed", reason: "Made-up reason.")
        P.reenter(ctx, P.of(task), trigger(:check_finished, check))
        event
      end

      later = written(key).drop(2)
      assert_equal %w[review.failed criterion.reopened cost.reported], later.map(&:type)
      later.each { |event| assert_equal [ "seat", @reviewer.id, finished.id ], [ event.actor_kind, event.actor_id, event.cause_id ] }
      assert_equal check.id, later.first.payload["failed_rule_check_id"]
      review_criterion = Criterion.find_by!(task_id: task.id, kind: "review")
      assert_equal [ review_criterion.id ], later.first.payload["failed_criterion_ids"]
      assert_equal [ "failed", check.id ], review.reload.values_at(:verdict, :failed_rule_check_id)
      assert_equal [ "working", 1 ], task.reload.values_at(:state, :round)
      assert_not Event.exists?(task_id: task.id, type: "review.passed")
    end
  end

  # --- a provisional claim -----------------------------------------------------------

  test "a claim that waits is provisional: the seat holds the Ready task with no lease and no event, and nobody else is offered it" do
    with_jobs do
      gating(custom_rule("task.before_claim"))
      task = @scenario.task(state: "ready")
      assert_equal :pending, command("claim", @builder).outcome
      assert_equal %w[check.queued job.queued], types

      task.reload
      assert_equal [ "ready", @builder.id, nil ], [ task.state, task.holder_seat_id, task.lease_due_at ]
      check = mine(RuleCheck).sole
      assert_equal [ "seat", @builder.id ], [ check.subject_kind, check.subject_id ]
      assert_equal @builder.id, written.first.payload["claimant_seat_id"]
      other = @scenario.seat(role: "builder", credential: @scenario.credential)
      assert_equal "not_eligible", command("claim", other).refusal.code
    end
  end

  test "a provisional claim completes as the claimant, with its key: task.claimed, the lease and the briefing in its result" do
    with_jobs do
      gating(custom_rule("task.before_claim"))
      task = @scenario.task(state: "ready")
      command("claim", @builder)
      key = @key
      check = mine(RuleCheck).sole
      in_command do |ctx|
        Leverage::RuleChecks.finish(ctx, check, result: "passed", reason: "Made-up reason.")
        P.reenter(ctx, P.of(task), trigger(:check_finished, check))
      end

      claimed = Event.find_by!(task_id: task.id, type: "task.claimed")
      assert_equal [ "seat", @builder.id, key ], [ claimed.actor_kind, claimed.actor_id, claimed.command_id ]
      assert_equal [ "working", @builder.id ], task.reload.values_at(:state, :holder_seat_id)
      assert_not_nil task.lease_due_at
      result = Command.find_by!(key: key).result
      assert_equal [ task.id, Leverage::Briefing.hash_for(task, seat: @builder) ], [ result.dig("task", "id"), result.dig("briefing", "hash") ]
    end
  end

  test "a failed claim check lapses the reservation: the task is Ready with no holder and the claim reads blocked_by_rule" do
    with_jobs do
      rule = custom_rule("task.before_claim")
      gating(rule)
      task = @scenario.task(state: "ready")
      command("claim", @builder)
      key = @key
      check = mine(RuleCheck).sole
      in_command do |ctx|
        Leverage::RuleChecks.finish(ctx, check, result: "failed", reason: "Made-up reason.")
        P.reenter(ctx, P.of(task), trigger(:check_finished, check))
      end

      assert_equal [ "ready", nil ], task.reload.values_at(:state, :holder_seat_id)
      assert_equal [ "refused", "blocked_by_rule", rule.id ],
        Command.find_by!(key: key).then { |row| [ row.outcome, row.refusal["code"], row.refusal["rule_id"] ] }
    end
  end

  # --- what the waiting seat may do (RE-4) ------------------------------------------

  test "under a pending submit the holder's pass_criterion answers pending and its heartbeat and release do not" do
    with_jobs do
      task, = pending_submit
      criterion = Criterion.find_by!(task_id: task.id, kind: "build")
      evidence = { "kind" => "link", "value" => "https://example.test/made-up-proof-2" }

      assert_equal "pending", command("pass_criterion", @builder, { "id" => task.id, "cid" => criterion.id,
        "evidence" => evidence }).refusal&.code
      assert_equal "pending", command("submit", @builder, submit_params(task, note: "Another note.")).refusal&.code
      assert command("heartbeat", @builder, { "id" => task.id }).completed?
      assert_not_equal "pending", command("release", @builder, { "id" => task.id, "reason" => "stopping" }).refusal&.code
    end
  end

  test "under a pending pass the reviewer's other verdict answers pending; a claimant's claim answers pending; the owner is not held back" do
    with_jobs do
      gating(custom_rule("task.before_done"), custom_rule("task.before_claim"))
      task, review = ready_for_verdict(@builder, @reviewer)
      command("pass_review", @reviewer, pass_params(review))
      failed = { "id" => review.id, "verdict" => "failed", "failed_criteria" => [ Criterion.find_by!(task_id: task.id, kind: "build").id ],
                 "notes" => "Made-up notes.", "tokens" => 1, "spend" => 0 }
      assert_equal "pending", command("fail_review", @reviewer, failed).refusal&.code

      @scenario.task(state: "ready")
      claimant = @scenario.seat(role: "builder", credential: @scenario.credential)
      assert_equal :pending, command("claim", claimant).outcome
      assert_equal "pending", command("claim", claimant).refusal&.code

      other = @scenario.task(state: "backlog")
      assert command("cancel", @owner, { "id" => other.id }).completed?
    end
  end

  # --- ending a waiting command from outside (rule 11) ------------------------------

  Leverage::PendingTransitions::ENDING_CODES.each do |code|
    test "cancel with #{code} withdraws the checks and their jobs, closes their holds, empties the request and refuses the command with #{code}" do
      with_jobs do
        task, pending, check, key = pending_submit
        hold = in_command do |ctx|
          T::Gate.open_hold(ctx, task, Leverage::Gating::PlannedHold.new(reason: "rerun_limit", rule_id: check.rule_id,
            rule_check_id: check.id), check_id: check.id)
        end
        job = Job.find(RuleCheckAttempt.find_by!(rule_check_id: check.id).job_id)

        events = in_command do |ctx|
          assert_nil P.cancel(ctx, pending, code)
          ctx.events
        end

        assert_equal %w[check.finished job.withdrawn hold.closed inbox.resolved], events.map(&:type)
        assert_equal [ "withdrawn", "withdrawn" ], [ check.reload.result, job.reload.state ]
        assert_equal "withdrawn", events.first.payload["result"]
        assert hold.reload.closed_at
        assert_equal [ "cancelled", nil ], pending.reload.values_at(:state, :params)
        row = Command.find_by!(key: key)
        assert_equal [ "refused", code, true ], [ row.outcome, row.refusal["code"], row.notify ]
        assert_equal "working", task.reload.state
      end
    end
  end

  test "a result that arrives after the cancel completes nothing" do
    with_jobs do
      task, pending, check, key = pending_submit
      in_command { |ctx| P.cancel(ctx, pending, "invalid_state") }

      events = in_command do |ctx|
        assert_nil P.reenter(ctx, pending, trigger(:check_finished, check))
        ctx.events
      end

      assert_empty events
      assert_equal "working", task.reload.state
      assert_equal "refused", Command.find_by!(key: key).outcome
    end
  end

  test "cancel inside a timer writes as the app, with no key and the timer's effective time" do
    with_jobs do
      _task, pending, _check, = pending_submit
      due = @scenario.database_now # after the check step opened, before the cancel's own time
      events = in_command do |ctx|
        P.cancel(ctx, pending, "lease_expired", actor_kind: "app", actor_id: nil, command_id: nil, effective_at: due)
        ctx.events
      end

      assert_equal %w[check.finished job.withdrawn], events.map(&:type)
      events.each { |event| assert_equal [ "app", nil, nil ], [ event.actor_kind, event.actor_id, event.command_id ] }
      events.each { |event| assert_in_delta due, event.effective_at, 0.001 }
    end
  end

  test "a cancelled provisional claim lapses its reservation" do
    with_jobs do
      gating(custom_rule("task.before_claim"))
      task = @scenario.task(state: "ready")
      command("claim", @builder)
      in_command { |ctx| P.cancel(ctx, P.of(task), "invalid_state") }

      assert_equal [ "ready", nil ], task.reload.values_at(:state, :holder_seat_id)
    end
  end

  # --- re-entry: the requester's refusals first (rule 9) ----------------------------

  test "a refusal the stored command now meets cancels it: invalid_state for a code that is not one of RC-17's three" do
    with_jobs do
      task, pending, check, key = pending_submit
      task.update_columns(holder_seat_id: nil) # not_holder, which RC-17 does not name
      in_command do |ctx|
        Leverage::RuleChecks.finish(ctx, check, result: "passed", reason: "Made-up reason.")
        P.reenter(ctx, pending, trigger(:check_finished, check))
      end

      assert_equal [ "refused", "invalid_state" ], Command.find_by!(key: key).then { |row| [ row.outcome, row.refusal["code"] ] }
      assert_equal "cancelled", pending.reload.state
      assert_equal "working", task.reload.state
    end
  end

  test "a refusal that is one of RC-17's three ends it with that code: a builder whose lease ended reads lease_expired" do
    with_jobs do
      task, pending, check, key = pending_submit
      Leverage::Leases.end_lease(nil, task)
      task.update_columns(holder_seat_id: nil, state: "ready")
      @scenario.append("task.lease_expired", task: task.reload, payload: { wait_cause: nil })
      in_command do |ctx|
        Leverage::RuleChecks.finish(ctx, check, result: "passed", reason: "Made-up reason.")
        P.reenter(ctx, pending, trigger(:check_finished, check))
      end

      assert_equal "lease_expired", Command.find_by!(key: key).refusal["code"]
      assert_equal "ready", task.reload.state
    end
  end

  test "a hold does not end the waiting command: its result waits for the last hold to lift (L378)" do
    with_jobs do
      task, pending, check, key = pending_submit
      Leverage::Gating.implementation.held = true
      @scenario.hold(task, reason: "owner_hold")
      in_command do |ctx|
        Leverage::RuleChecks.finish(ctx, check, result: "passed", reason: "Made-up reason.")
        assert_equal :keep_pending, P.reenter(ctx, pending, trigger(:check_finished, check)).action
      end

      assert_equal [ "pending", "pending" ], [ pending.reload.state, Command.find_by!(key: key).outcome ]
    end
  end

  test "an errored check keeps the transition pending and opens check_error with its item, naming the check" do
    with_jobs do
      task, pending, check, = pending_submit
      in_command do |ctx|
        Leverage::RuleChecks.error(ctx, check, actor_kind: "app", actor_id: nil, command_id: nil)
        P.reenter(ctx, pending, trigger(:check_timed_out, check), actor_kind: "app", actor_id: nil, command_id: nil)
      end

      hold = Hold.find_by!(task_id: task.id, reason: "check_error")
      assert_equal [ check.rule_id, check.id ], [ hold.rule_id, hold.rule_check_id ]
      opened = Event.find_by!(subject_id: hold.id, type: "hold.opened")
      assert_equal [ "app", Leverage::RuleChecks.last_finished(check).id ], [ opened.actor_kind, opened.cause_id ]
      assert_equal({ "rule_id" => check.rule_id, "rule_check_id" => check.id }, InboxItem.find_by!(hold_id: hold.id).facts)
      assert_equal "pending", pending.reload.state
    end
  end

  test "re-entry that meets the same errored check again opens no second check_error hold" do
    with_jobs do
      task, pending, check, = pending_submit
      in_command do |ctx|
        Leverage::RuleChecks.error(ctx, check)
        P.reenter(ctx, pending, trigger(:check_timed_out, check))
        P.reenter(ctx, pending, trigger(:check_timed_out, check))
      end

      assert_equal 1, mine(Hold).where(task_id: task.id, reason: "check_error").count
    end
  end

  test "a re-run's result closes its check_error hold with run_again, as the app, caused by its check.finished, then completes (trace 19, command 21)" do
    with_jobs do
      rule = custom_rule("task.before_ready", route: "owner")
      gating(rule)
      task = @scenario.task(state: "backlog")
      command("complete_contract", @owner, contract_params(task))
      key = @key
      pending = P.of(task)
      check = mine(RuleCheck).sole
      in_command do |ctx|
        Leverage::RuleChecks.error(ctx, check, actor_kind: "app", actor_id: nil, command_id: nil)
        P.reenter(ctx, pending, trigger(:check_timed_out, check), actor_kind: "app", actor_id: nil, command_id: nil)
      end
      in_command { |ctx| Leverage::RuleChecks.queue_attempt(ctx, check) }

      events = in_command(request: T::Request.new(command: "submit_job_result", workspace_id: @scenario.workspace_id,
        caller_kind: "seat", caller_id: @scenario.orchestrator.id, key: "k-result", request_hash: nil, params: {})) do |ctx|
        Leverage::RuleChecks.finish(ctx, check, result: "passed", reason: "Made-up reason.")
        P.reenter(ctx, pending, trigger(:check_finished, check))
        ctx.events
      end

      finished, closed, resolved, changed, ready = events
      assert_equal %w[check.finished hold.closed inbox.resolved task.contract_changed task.ready], events.map(&:type)
      assert_equal [ "app", nil, "k-result", finished.id ], [ closed.actor_kind, closed.actor_id, closed.command_id, closed.cause_id ]
      assert_equal "run_again", resolved.payload["choice"]
      [ changed, ready ].each { |event| assert_equal [ "owner", key, finished.id ], [ event.actor_kind, event.command_id, event.cause_id ] }
    end
  end

  test "a task has one pending transition: the owner's second Complete contract while one waits answers pending" do
    with_jobs do
      gating(custom_rule("task.before_ready", route: "owner"))
      task = @scenario.task(state: "backlog")
      assert_equal :pending, command("complete_contract", @owner, contract_params(task)).outcome
      second = command("complete_contract", @owner, contract_params(task, details: "Other details."))

      assert_equal "pending", second.refusal&.code
      assert_equal 1, mine(PendingTransition).where(task_id: task.id).count
    end
  end

  # --- run_as (RE-6) ------------------------------------------------------------------

  test "run_as runs Complete contract as a planner inside the caller's transaction, with the given key: completed" do
    gating(app_rule("task.before_ready"))
    planner = @scenario.planner
    task = @scenario.task(state: "backlog")
    answer, events = in_command do |ctx|
      [ T.run_as(ctx, "complete_contract", requester: planner, key: "k-draft-result", params: contract_params(task)), ctx.events ]
    end

    assert_equal :completed, answer
    assert_equal %w[check.finished task.contract_changed task.ready], events.map(&:type)
    events.each { |event| assert_equal [ "seat", planner.id, "k-draft-result" ], [ event.actor_kind, event.actor_id, event.command_id ] }
    assert_equal "ready", task.reload.state
  end

  test "run_as answers pending when the gate waits: the transition is the planner's, under the given key, and completes as the planner" do
    with_jobs do
      rule = custom_rule("task.before_ready", route: "owner")
      gating(rule)
      planner = @scenario.planner
      task = @scenario.task(state: "backlog")
      answer = in_command do |ctx|
        T.run_as(ctx, "complete_contract", requester: planner, key: "k-draft-result", params: contract_params(task))
      end
      assert_equal :pending, answer
      pending = P.of(task)
      assert_equal [ "seat", planner.id, "k-draft-result" ], pending.values_at(:requester_kind, :requester_id, :command_key)

      check = RuleCheck.find_by!(rule_id: rule.id)
      in_command do |ctx|
        Leverage::RuleChecks.finish(ctx, check, result: "passed", reason: "Made-up reason.")
        P.reenter(ctx, pending, trigger(:check_finished, check))
      end
      ready = Event.find_by!(task_id: task.id, type: "task.ready")
      assert_equal [ "seat", planner.id, "k-draft-result" ], [ ready.actor_kind, ready.actor_id, ready.command_id ]
    end
  end

  test "run_as answers refused for a refusal of the entry's, and writes nothing" do
    task = @scenario.task(state: "ready")
    answer, events = in_command do |ctx|
      [ T.run_as(ctx, "complete_contract", requester: @scenario.planner, key: "k-late", params: contract_params(task)), ctx.events ]
    end

    assert_equal :refused, answer
    assert_empty events
  end
end
