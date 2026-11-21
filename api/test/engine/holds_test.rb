require "test_helper"
require_relative "entries/pending_stub"

# Leverage::Holds (PRD L121, L150-L201; registry hold_reasons; milestone 2
# plan WP4, EN-13, EN-31; contract decisions DB-20, DB-35): a hold row with
# hold.opened and its Needs you item; a hold whose reason pauses the lease
# clock pauses both the builder's lease on the task and the reviewer's on
# its open review, and a lease granted while it is open starts paused;
# closing the last pausing hold restarts both clocks from the command's time
# with the time they had left, and the last hold on a task a seat holds
# sets tasks.resume_pending_since.
class HoldsTest < ActiveSupport::TestCase
  include PendingStub

  H = Leverage::Holds

  setup do
    @scenario = Scenario.new(lease_length_seconds: 600)
    @builder = @scenario.seat(role: "builder")
    @reviewer = @scenario.seat(role: "reviewer")
  end

  def context(at: nil, key: "k-#{SecureRandom.hex(4)}", caller: [ "owner", @scenario.owner.id ])
    request = Leverage::Transitions::Request.new(command: "test", workspace_id: @scenario.workspace_id,
      caller_kind: caller.first, caller_id: caller.last, key: key, request_hash: nil, params: {})
    @scenario.context(at: at, request: request)
  end

  def working_task
    @scenario.task(state: "working", builder: @builder).tap do |task|
      @scenario.append("task.briefing_acknowledged", task: task, actor_kind: "seat", actor_id: @builder.id)
    end
  end

  def left(record) = record.reload.lease_time_left_while_paused&.to_i

  test "a stopped action offers override only for a failed check and rework only before a start" do
    task = working_task
    ctx = context
    action_id = SecureRandom.uuid
    facts = { action_id: action_id, rule_check_id: nil, any_action_started: true }
    hold = H.open(ctx, task: task, reason: "action_stopped", facts: facts)
    item = InboxItem.find_by!(hold_id: hold.id)

    assert_equal facts.stringify_keys, item.facts
    assert_equal %w[waive cancel], item.choices

    hold = H.open(ctx, task: task, reason: "action_stopped",
      facts: facts.merge(rule_check_id: SecureRandom.uuid, any_action_started: false))
    assert_equal %w[waive return_for_rework cancel override_once], InboxItem.find_by!(hold_id: hold.id).choices
  end

  test "closing the last hold under a fresh action lease leaves an acknowledgement due without resume" do
    task = @scenario.finishing_task(builder: @builder, holder: false,
      actions: [ { kind: "send", description: "Send the example.", state: "approved" } ])
    hold = H.open(context, task: task, reason: "action_unconfirmed")
    ctx = context

    task.update!(holder_seat_id: @builder.id)
    Leverage::Leases.grant(ctx, task, paused: true)
    H.close(ctx, hold: hold, task: task, lease_seat_id: @builder.id, choice: "offer_again")

    assert_nil task.reload.resume_pending_since
    assert_equal ctx.at + 600, task.lease_due_at
  end

  test "open writes the hold, hold.opened, the Needs you item and inbox.opened caused by it" do
    task = working_task
    ctx = context
    hold = H.open(ctx, task: task, reason: "rounds_exceeded", facts: {})

    assert_equal [ "rounds_exceeded", ctx.at, nil ], [ hold.reason, hold.opened_at, hold.closed_at ]
    opened, inbox = ctx.events.last(2)
    assert_equal [ "hold.opened", hold.id, "app" ], [ opened.type, opened.subject_id, opened.actor_kind ]
    assert_equal [ "inbox.opened", opened.id ], [ inbox.type, inbox.cause_id ]
    item = InboxItem.find(inbox.subject_id)
    assert_equal [ "past_round_limit", hold.id, "open" ], [ item.kind, item.hold_id, item.state ]
  end

  test "a hold that pauses stops the builder's lease clock and keeps the time it had left" do
    task = working_task
    ctx = context
    task.update_columns(lease_due_at: ctx.at + 250)
    H.open(ctx, task: task, reason: "rounds_exceeded")

    assert_nil task.reload.lease_due_at, "a paused lease has no running clock"
    assert_equal 250, left(task)
    assert H.pausing?(task)
  end

  test "a hold that pauses also stops the reviewer's lease clock on the open review (DB-20)" do
    task = @scenario.task(state: "in_review", builder: @builder)
    review = @scenario.review(task, reviewer: @reviewer)
    ctx = context
    review.update_columns(lease_due_at: ctx.at + 400)
    H.open(ctx, task: task, reason: "owner_hold")

    assert_nil review.reload.lease_due_at
    assert_equal 400, left(review)
  end

  test "a hold whose lease clock runs pauses nothing" do
    task = working_task
    ctx = context
    due = task.lease_due_at
    H.open(ctx, task: task, reason: "seat_paused")

    assert_equal due, task.reload.lease_due_at
    assert_nil left(task)
    refute H.pausing?(task)
    assert H.held?(task)
  end

  test "a second pausing hold keeps the time left from the first" do
    task = working_task
    ctx = context
    task.update_columns(lease_due_at: ctx.at + 250)
    H.open(ctx, task: task, reason: "owner_hold")
    later = context(at: ctx.at + 100)
    H.open(later, task: task, reason: "rounds_exceeded")

    assert_equal 250, left(task)
  end

  test "a lease granted while a pausing hold is open starts paused, with the whole length left" do
    task = working_task
    ctx = context
    H.open(ctx, task: task, reason: "rounds_exceeded")
    Leverage::Leases.grant(ctx, task)
    H.pause_if_held(ctx, task)

    assert_nil task.reload.lease_due_at
    assert_equal 600, left(task)

    Leverage::Leases.grant(ctx, task, paused: H.pausing?(task))
    assert_equal [ nil, 600 ], [ task.reload.lease_due_at, left(task) ], "the same, through grant's paused:"

    free = @scenario.task(state: "working", builder: @scenario.seat(role: "builder"))
    due = free.lease_due_at
    H.pause_if_held(ctx, free)
    assert_equal due, free.reload.lease_due_at, "a task with no hold keeps its running clock"
  end

  test "closing the last pausing hold restarts both clocks from the command's time and sets resume_pending_since" do
    task = working_task
    ctx = context
    task.update_columns(lease_due_at: ctx.at + 250)
    hold = H.open(ctx, task: task, reason: "rounds_exceeded")

    later = context(at: ctx.at + 3600)
    H.close(later, hold: hold, task: task.reload, choice: "allow_another_round")
    task.reload
    assert_equal later.at + 250, task.lease_due_at
    assert_nil task.lease_time_left_while_paused
    assert_equal later.at, task.resume_pending_since
    closed, resolved = later.events.last(2)
    assert_equal [ "hold.closed", "inbox.resolved", { "choice" => "allow_another_round" } ],
      [ closed.type, resolved.type, resolved.payload ]
    assert_equal "resolved", InboxItem.find(resolved.subject_id).state
  end

  test "trace 10's lease: granted at 2150, paused at once by the hold, resumed at 2200, due at 2800" do
    task = working_task
    start = @scenario.database_now
    verdict = context(at: start + 2150)
    Leverage::Leases.grant(verdict, task)
    hold = H.open(verdict, task: task, reason: "rounds_exceeded")
    assert_equal 600, left(task)

    allow = context(at: start + 2200)
    H.close(allow, hold: hold, task: task.reload, choice: "allow_another_round")
    assert_equal start + 2800, task.reload.lease_due_at
  end

  # Review: a timer closes a hold at its due time, which can be earlier
  # than the command that writes it (the sweep looks every 15 s). The lease
  # runs again from the hold's effective close, so the delay gives it no
  # time (PRD L118).
  test "a hold closed at an earlier effective time restarts the lease from that time, not the command's (review)" do
    credential = @scenario.credential
    task = working_task
    ctx = context
    task.update_columns(lease_due_at: ctx.at + 250)
    hold = H.open(ctx, task: task, reason: "credential_signed_out", credential_id: credential.id)

    later = context(at: ctx.at + 600)
    H.close(later, hold: hold, task: task.reload, effective_at: ctx.at + 300, command_id: nil, actor_kind: "app",
      actor_id: nil)

    assert_equal ctx.at + 300 + 250, task.reload.lease_due_at
    assert_nil task.lease_time_left_while_paused
  end

  test "closing one hold while another pausing hold is open keeps the clock paused and sets no resume" do
    task = working_task
    ctx = context
    task.update_columns(lease_due_at: ctx.at + 250)
    first = H.open(ctx, task: task, reason: "owner_hold")
    H.open(ctx, task: task, reason: "rounds_exceeded")
    H.close(context(at: ctx.at + 60), hold: first, task: task.reload)

    assert_nil task.reload.lease_due_at
    assert_equal 250, left(task)
    assert_nil task.resume_pending_since
  end

  test "closing a hold restarts the reviewer's lease too" do
    task = @scenario.task(state: "in_review", builder: @builder)
    review = @scenario.review(task, reviewer: @reviewer)
    ctx = context
    review.update_columns(lease_due_at: ctx.at + 400)
    hold = H.open(ctx, task: task, reason: "owner_hold")
    later = context(at: ctx.at + 30)
    H.close(later, hold: hold, task: task.reload)

    assert_equal later.at + 400, review.reload.lease_due_at
    assert_nil task.reload.resume_pending_since, "no seat holds a task in review"
  end

  test "a hold closed by Cancel sets no resume (EN-30)" do
    task = working_task
    ctx = context
    hold = H.open(ctx, task: task, reason: "rounds_exceeded")
    cancel = context(at: ctx.at + 10)
    task.reload.update!(state: "cancelled")
    cancel.emit("task.cancelled", task: task)
    H.close(cancel, hold: hold, task: task, choice: "cancel")

    assert_nil task.reload.resume_pending_since
  end

  test "the oldest open hold is the first one opened, in log order" do
    task = working_task
    ctx = context
    first = H.open(ctx, task: task, reason: "owner_hold")
    second = H.open(ctx, task: task, reason: "rounds_exceeded")

    assert_equal [ first.id, second.id ], H.open_holds(task).map(&:id)
    assert_equal first.id, H.oldest_open(task).id
    H.close(ctx, hold: first, task: task)
    assert_equal second.id, H.oldest_open(task).id
  end

  test "the step follows the hold: wait_owner opens on the hold and closing it opens the interrupted work again" do
    task = working_task
    ctx = context
    hold = H.open(ctx, task: task, reason: "rounds_exceeded")
    assert_equal [ "wait_owner", hold.id ], TaskStep.find_by!(task_id: task.id, closed_at: nil).values_at(:kind, :subject_id)

    H.close(context(at: ctx.at + 5), hold: hold, task: task.reload)
    assert_equal "build", TaskStep.find_by!(task_id: task.id, closed_at: nil).kind
  end

  # --- Milestone 3 (plan WP4): the four hold reasons of the handoff, the
  # seat-bound close, and what a timer's or a handoff's close needs. ------

  # Each reason's lease clock, as the registry's lease_clock column says:
  # credential_limit and seat_paused let the lease run (L121, L697),
  # credential_signed_out and owner_hold pause it.
  {
    "credential_limit" => false, "credential_signed_out" => true, "seat_paused" => false, "owner_hold" => true
  }.each do |reason, pauses|
    test "#{reason} #{pauses ? "pauses" : "does not pause"} the builder's lease clock, as the registry says" do
      registry = Leverage::Contract.registry.fetch("hold_reasons").find { |entry| entry.fetch("reason") == reason }
      assert_equal pauses ? "pauses" : "runs", registry.fetch("lease_clock")

      credential = @scenario.credential if reason.start_with?("credential")
      task = working_task
      ctx = context
      task.update_columns(lease_due_at: ctx.at + 250)
      hold = H.open(ctx, task: task, reason: reason, credential_id: credential&.id, item: false)

      assert_equal pauses, H.pausing?(task)
      assert_equal(pauses ? [ nil, 250 ] : [ ctx.at + 250, nil ], [ task.reload.lease_due_at, left(task) ])
      H.close(context(at: ctx.at + 100), hold: hold, task: task.reload)
      assert_equal(pauses ? ctx.at + 100 + 250 : ctx.at + 250, task.reload.lease_due_at)
    end
  end

  test "two holds stacked follow the oldest: wait_seat, then wait_limit when seat_paused closes, each naming the seat" do
    credential = @scenario.credential
    task = working_task
    ctx = context
    paused = H.open(ctx, task: task, reason: "seat_paused")
    later = context(at: ctx.at + 10)
    H.open(later, task: task, reason: "credential_limit", credential_id: credential.id, item: false)
    assert_equal [ "wait_seat", "seat", @builder.id, @builder.id ],
      TaskStep.find_by!(task_id: task.id, closed_at: nil).values_at(:kind, :subject_kind, :subject_id, :seat_id)

    H.close(context(at: ctx.at + 20), hold: paused, task: task.reload)
    assert_equal [ "wait_limit", "credential", credential.id, @builder.id ],
      TaskStep.find_by!(task_id: task.id, closed_at: nil).values_at(:kind, :subject_kind, :subject_id, :seat_id)
  end

  test "close takes the effective time, the key and the actor a timer gives, and yields hold.closed before inbox.resolved" do
    credential = @scenario.credential
    task = working_task
    ctx = context
    hold = H.open(ctx, task: task, reason: "credential_signed_out", credential_id: credential.id)
    later = context(at: ctx.at + 600)
    between = nil

    H.close(later, hold: hold, task: task.reload, effective_at: ctx.at + 300, command_id: nil, actor_kind: "app",
      actor_id: nil) do |closed|
      between = later.emit("credential.switched", task: task, subject: credential, cause_id: closed.id, command_id: nil,
        actor_kind: "app", actor_id: nil, effective_at: ctx.at + 300,
        payload: { from_credential_id: credential.id, model: nil, seat_id: @builder.id, review_id: nil, job_id: nil })
    end

    closed, switched, resolved = later.events.last(3)
    assert_equal %w[hold.closed credential.switched inbox.resolved], [ closed.type, switched.type, resolved.type ]
    assert_equal between.id, switched.id
    [ closed, resolved ].each do |event|
      assert_equal [ ctx.at + 300, nil, "app", nil ], [ event.effective_at, event.command_id, event.actor_kind, event.actor_id ]
    end
    assert_equal [ "app", nil, later.at ], hold.reload.values_at(:closed_by_kind, :closed_by_id, :closed_at)
  end

  test "close_seat_bound closes the seat-bound holds oldest first, each hold.closed then its item, as the cause's actor" do
    credential = @scenario.credential
    task = working_task
    ctx = context
    owner_hold = H.open(ctx, task: task, reason: "owner_hold")
    paused = H.open(ctx, task: task, reason: "seat_paused")
    signed_out = H.open(ctx, task: task, reason: "credential_signed_out", credential_id: credential.id)
    release = context(at: ctx.at + 50, caller: [ "seat", @builder.id ])
    released = release.emit("task.released", task: task, payload: { reason: "unable_to_continue", wait_cause: nil })

    closed = H.close_seat_bound(release, task, cause: released, wait_cause: "credential_limit")

    assert_equal [ paused.id, signed_out.id ], closed.map(&:id)
    events = release.events.drop(1)
    assert_equal %w[hold.closed hold.closed inbox.resolved], events.map(&:type)
    events.each do |event|
      assert_equal [ "seat", @builder.id, released.effective_at, released.command_id, nil ],
        [ event.actor_kind, event.actor_id, event.effective_at, event.command_id, event.cause_id ]
    end
    assert_equal [ nil, nil ], events.first(2).map { |event| event.payload.fetch("wait_cause") },
      "owner_hold stays open, so no wait_ready opens and no hold.closed carries the cause"
    assert_nil owner_hold.reload.closed_at
    assert_equal({ "choice" => nil }, events.last.payload)
  end

  test "close_seat_bound puts the wait_cause on the last hold.closed when no hold is left, as a timer's events" do
    credential = @scenario.credential
    task = working_task
    ctx = context
    first = H.open(ctx, task: task, reason: "credential_limit", credential_id: credential.id, item: false)
    second = H.open(ctx, task: task, reason: "seat_paused")
    timer = context(at: ctx.at + 100)
    expired = timer.emit("task.lease_expired", task: task, payload: { wait_cause: nil }, actor_kind: "app", actor_id: nil,
      command_id: nil, effective_at: ctx.at + 60)

    H.close_seat_bound(timer, task, cause: expired, wait_cause: "credential_limit")

    first_closed, second_closed = timer.events.drop(1)
    assert_equal [ first.id, second.id ], [ first_closed.subject_id, second_closed.subject_id ]
    assert_equal [ nil, "credential_limit" ], [ first_closed, second_closed ].map { |event| event.payload.fetch("wait_cause") }
    assert_equal [ "app", nil, nil, ctx.at + 60 ],
      [ second_closed.actor_kind, second_closed.actor_id, second_closed.command_id, second_closed.effective_at ]
  end

  test "close_seat_bound with no seat-bound hold open closes nothing" do
    task = working_task
    ctx = context
    H.open(ctx, task: task, reason: "owner_hold")
    released = ctx.emit("task.released", task: task, payload: { reason: "unable_to_continue", wait_cause: nil })

    assert_empty H.close_seat_bound(ctx, task, cause: released, wait_cause: nil)
    assert_equal %w[hold.opened task.released], ctx.events.map(&:type)
  end

  # --- Milestone 4 (plan WP5): the four rule holds, and a hold over a
  # waiting command (PRD L161-L167, L378, L392; RD-13, RD-45, SM-24,
  # SM-39; §2.1 rules 9 to 11). PendingTransitions is WP4's: PendingStub
  # stands in for it and records what Holds asks of it. ------------------

  # Each rule hold's lease clock, the step it opens (the registry's step:
  # contract_incomplete waits on the contract, the others on the owner)
  # and its Needs you item, from a task in the state the hold opens in.
  {
    "contract_incomplete" => [ "backlog", false, "wait_contract", nil ],
    "check_error" => [ "working", true, "wait_owner", "check_could_not_run" ],
    "claim_gate_failed" => [ "ready", false, "wait_owner", "refused_for_every_agent" ],
    "rerun_limit" => [ "working", true, "wait_owner", "check_past_rerun_limit" ]
  }.each do |reason, (state, pauses, step, item)|
    test "#{reason}: its rule on hold.opened, #{pauses ? "a paused" : "no"} lease clock, step #{step}, item #{item.inspect}" do
      rule = @scenario.rule
      task = state == "working" ? working_task : @scenario.task(state: state)
      check = @scenario.rule_check(task, rule: rule, result: "failed")
      ctx = context
      task.update_columns(lease_due_at: ctx.at + 250) if state == "working"
      hold = H.open(ctx, task: task, reason: reason, rule_id: rule.id, facts: {}, rule_check_id: check.id)

      opened = ctx.events.find { |event| event.type == "hold.opened" }
      # The rule check a rule's hold is about, for the three reasons that
      # name one (DB-49), on the row and in the event.
      named = H::NAMES_CHECK.include?(reason) ? check.id : nil
      assert_equal({ "reason" => reason, "rule_id" => rule.id, "credential_id" => nil, "rule_check_id" => named }, opened.payload)
      assert_equal check.id, hold.rule_check_id
      assert_equal pauses, H.pausing?(task)
      assert_equal 250, left(task) if pauses
      open = TaskStep.find_by!(task_id: task.id, closed_at: nil)
      assert_equal [ step, opened.id ], [ open.kind, open.opening_event_id ],
        "the hold opens its own step, a new wait_contract row for contract_incomplete too (SM-24)"
      item ? assert_equal(item, InboxItem.find_by(hold_id: hold.id)&.kind) : assert_not(InboxItem.exists?(hold_id: hold.id))
    end
  end

  test "check_error opens its task item only when the caller says the orchestrator is online (SM-39)" do
    rule = @scenario.rule
    first = working_task
    online = H.open(context, task: first, reason: "check_error", rule_id: rule.id, item: true)
    second = @scenario.task(state: "working", builder: @scenario.seat(role: "builder"))
    offline = H.open(context, task: second, reason: "check_error", rule_id: rule.id, item: false)

    assert_equal "check_could_not_run", InboxItem.find_by!(hold_id: online.id).kind
    assert_not InboxItem.exists?(hold_id: offline.id), "the workspace's Orchestrator offline item covers it"
    assert_equal 1, Event.where(type: "inbox.opened", task_id: [ online.task_id, offline.task_id ]).count
  end

  test "a hold over a pending submit makes the open step the hold's and cancels nothing (L378)" do
    task = working_task
    pending = @scenario.pending_transition(task, command: "submit", requester: @builder)
    hold = nil
    calls = with_pending(pending) { hold = H.open(context, task: task, reason: "owner_hold") }

    assert_empty calls
    assert_equal [ "wait_owner", hold.id ], TaskStep.find_by!(task_id: task.id, closed_at: nil).values_at(:kind, :subject_id)
    assert_equal "pending", pending.reload.state
  end

  test "the last hold lifting re-enters the pending transition once, with the trigger hold_lifted (L378, rule 9)" do
    task = working_task
    pending = @scenario.pending_transition(task, command: "submit", requester: @builder)
    first = H.open(context, task: task, reason: "owner_hold")
    second = H.open(context, task: task, reason: "rounds_exceeded", facts: { round: 0 })

    calls = with_pending(pending) { H.close(context, hold: first, task: task.reload) }
    assert_empty calls, "a hold is still open: nothing re-enters (rule 9)"

    closing = context
    calls = with_pending(pending) { H.close(closing, hold: second, task: task.reload, choice: "allow_another_round") }
    assert_equal [ [ :reenter, pending.id, :hold_lifted ] ], calls.map(&:summary)
    assert_nil calls.sole.argument.rule_check_id
    assert_equal %w[hold.closed inbox.resolved], calls.sole.written_before.last(2),
      "it re-enters after the hold has closed and its item is resolved"
  end

  # Override, Run it again, the re-run's result, a rule turned off and a
  # cancel each close the check's hold and gate the transition with the
  # check themselves (override_check.rb, rule_records.rb): Holds does not
  # gate it a second time in the same command.
  %w[check_error rerun_limit].each do |reason|
    test "the last hold lifting is #{reason}, a check's own hold: Holds leaves the re-entry to its closer" do
      task = working_task
      pending = @scenario.pending_transition(task, command: "submit", requester: @builder)
      rule = @scenario.rule
      hold = H.open(context, task: task, reason: reason, rule_id: rule.id)

      assert_empty(with_pending(pending) { H.close(context, hold: hold, task: task.reload) })
    end
  end

  test "closing the last hold re-enters nothing with no pending transition, on a cancelled task, or inside the waiting command" do
    task = working_task
    hold = H.open(context, task: task, reason: "owner_hold")
    assert_empty(with_pending(nil) { H.close(context, hold: hold, task: task.reload) })

    pending = @scenario.pending_transition(task, command: "submit", requester: @builder)
    hold = H.open(context, task: task, reason: "owner_hold")
    performing = context(key: pending.command_key, caller: [ "seat", @builder.id ])
    calls = with_pending(pending) { H.close(performing, hold: hold, task: task.reload) }
    assert_empty calls, "a hold the waiting command closes while it is performed does not re-enter it"

    hold = H.open(context, task: task, reason: "owner_hold")
    cancel = context
    task.reload.update!(state: "cancelled", holder_seat_id: nil, builder_seat_id: nil)
    cancel.emit("task.cancelled", task: task)
    assert_empty(with_pending(pending) { H.close(cancel, hold: hold, task: task, choice: "cancel") })
  end

  # RD-13, rule 11: the reservation lapses whatever opens the hold: the
  # owner's hold, or a rule hold the app opens.
  { "owner_hold" => [ "owner" ], "claim_gate_failed" => [ "app" ] }.each do |reason, (actor)|
    test "#{reason} opened on a Ready task with a provisional claim cancels the claim invalid_state, first (RD-13)" do
      task = @scenario.task(state: "ready")
      task.update_columns(holder_seat_id: @builder.id)
      pending = @scenario.pending_transition(task, command: "claim", requester: @builder)
      actor_id = actor == "owner" ? @scenario.owner.id : nil
      rule_id = @scenario.rule.id if reason == "claim_gate_failed"
      calls = with_pending(pending) do
        H.open(context, task: task, reason: reason, rule_id: rule_id, actor_kind: actor, actor_id: actor_id)
      end

      assert_equal [ [ :cancel, pending.id, "invalid_state" ] ], calls.map(&:summary)
      assert_not_includes calls.sole.written_before, "hold.opened", "the claim is cancelled before hold.opened"
    end
  end

  test "a hold on a Ready task with no provisional claim cancels nothing" do
    task = @scenario.task(state: "ready")
    assert_empty(with_pending(nil) { H.open(context, task: task, reason: "owner_hold") })
  end
end
