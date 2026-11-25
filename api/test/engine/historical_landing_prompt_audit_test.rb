require "test_helper"

class HistoricalLandingPromptAuditTest < ActiveSupport::TestCase
  setup do
    @scenario = Scenario.new
    @seat = @scenario.seat(role: "general")
    @request = Leverage::Transitions::Request.new(command: "issue_landing_prompt", workspace_id: @scenario.workspace_id,
      caller_kind: "owner", caller_id: @scenario.owner.id, key: "historical-prompt", request_hash: "p" * 64, params: {})
    @command = Command.create!(workspace_id: @request.workspace_id, caller_kind: @request.caller_kind, caller_id: @request.caller_id,
      command: @request.command, key: @request.key, request_hash: @request.request_hash, outcome: "completed",
      result: { seat_id: @seat.id, connection: "http" })
  end

  # A check of the seat's waiting command held at the re-run limit: a row
  # with no attempt and no check.queued (RD-45), under the rerun_limit
  # hold the waiting command opened with its own key.
  def held_at_rerun_limit(task, pending, hook:, subject: nil, key: pending.command_key)
    check = @scenario.rule_check(task, rule: @scenario.rule(hook: hook), subject: subject, pending: pending, attempts: 0)
    sent = Leverage::Transitions::Request.new(command: pending.command, workspace_id: @scenario.workspace_id, caller_kind: "seat",
      caller_id: pending.requester_id, key: key, request_hash: "s" * 64, params: {})
    Leverage::Transitions::Gate.open_hold(@scenario.context(request: sent), task,
      Leverage::Gating::PlannedHold.new(reason: "rerun_limit", rule_id: check.rule_id, rule_check_id: check.id), check_id: check.id)
    refute Event.exists?(workspace_id: @scenario.workspace_id, type: "check.queued", subject_id: check.id)
    check
  end

  def key_events = Event.where(workspace_id: @scenario.workspace_id, command_id: @request.key).order(:seq).to_a

  def audit(after) = Leverage::LogAudit.call(@scenario.workspace_id, after_seq: after)

  test "a New prompt that released its Working task passes the audit" do
    task = @scenario.task(state: "working", builder: @seat)
    pending = @scenario.pending_transition(task, command: "submit", requester: @seat)
    @scenario.rule_check(task, rule: @scenario.rule(hook: "task.before_submit"), pending: pending)
    @scenario.hold(task, reason: "seat_paused")
    after = @scenario.workspace.reload.last_seq
    ctx = @scenario.context(request: @request)
    released = Leverage::SeatRuns.release_working_task(ctx, @seat, reason: "new_prompt")
    assert_equal [ task.id, "new_prompt", @request.key ], [ released.task_id, released.payload["reason"], released.command_id ]
    events = Event.where(workspace_id: @scenario.workspace_id, command_id: @request.key).order(:seq)
    assert_equal %w[check.finished job.withdrawn task.released hold.closed], events.pluck(:type)
    assert_empty Leverage::LogAudit.call(@scenario.workspace_id, after_seq: after)
    @command.destroy!
    assert_empty Leverage::LogAudit.call(@scenario.workspace_id, after_seq: after)
  end

  test "a New prompt held a Finishing task with an approved action" do
    task = @scenario.finishing_task(builder: @seat, actions: [ { kind: "send", description: "Send the sample.", state: "approved" } ])
    after = @scenario.workspace.reload.last_seq
    Leverage::Finishing.lose_builder(@scenario.context(request: @request), task, cause: nil)
    events = Event.where(workspace_id: @scenario.workspace_id, command_id: @request.key).order(:seq)
    assert_equal %w[hold.opened inbox.opened], events.pluck(:type)
    assert_empty Leverage::LogAudit.call(@scenario.workspace_id, after_seq: after)
  end

  test "a New prompt that released its review passes the audit" do
    task = @scenario.task(state: "in_review")
    @scenario.review(task, reviewer: @seat)
    after = @scenario.workspace.reload.last_seq
    released = Leverage::SeatRuns.release_held_reviews(@scenario.context(request: @request), @seat).sole
    assert_equal [ "review.released", @request.key ], [ released.type, released.command_id ]
    assert_empty Leverage::LogAudit.call(@scenario.workspace_id, after_seq: after)
    @command.destroy! # After the command key retention period.
    assert_empty Leverage::LogAudit.call(@scenario.workspace_id, after_seq: after)
  end

  test "a New prompt that cancelled a pass held at the re-run limit passes the audit" do
    task = @scenario.task(state: "in_review")
    review = @scenario.review(task, reviewer: @seat)
    pending = @scenario.pending_transition(task, command: "pass_review", requester: @seat)
    held_at_rerun_limit(task, pending, hook: "task.before_done", subject: review)
    after = @scenario.workspace.reload.last_seq
    Leverage::SeatRuns.release_held_reviews(@scenario.context(request: @request), @seat)
    assert_equal %w[check.finished hold.closed inbox.resolved review.released], key_events.map(&:type)
    assert_equal "cancelled", pending.reload.state
    assert_empty audit(after)
  end

  test "a held check whose re-run limit hold another key opened is not the New prompt's to withdraw" do
    task = @scenario.task(state: "working", builder: @seat)
    pending = @scenario.pending_transition(task, command: "submit", requester: @seat)
    held_at_rerun_limit(task, pending, hook: "task.before_submit", key: "another-key")
    after = @scenario.workspace.reload.last_seq
    Leverage::SeatRuns.release_working_task(@scenario.context(request: @request), @seat, reason: "new_prompt")
    assert_equal %w[check.finished hold.closed inbox.resolved task.released], key_events.map(&:type)
    assert_match(/issue_landing_prompt wrote task\.released/, audit(after).sole)
  end

  # --- what the reading does not cover: only the receipt's seat's own work ------

  test "a New prompt receipt does not excuse the release of another seat's Working task" do
    other = @scenario.seat(role: "general")
    @scenario.task(state: "working", builder: other)
    after = @scenario.workspace.reload.last_seq
    released = Leverage::SeatRuns.release_working_task(@scenario.context(request: @request), other, reason: "new_prompt")
    assert_equal [ "owner", "new_prompt" ], [ released.actor_kind, released.payload["reason"] ]
    assert_match(/issue_landing_prompt wrote task\.released/, audit(after).sole)
  end

  test "a New prompt receipt does not excuse the release of another seat's review" do
    other = @scenario.seat(role: "general")
    @scenario.review(@scenario.task(state: "in_review"), reviewer: other)
    after = @scenario.workspace.reload.last_seq
    Leverage::SeatRuns.release_held_reviews(@scenario.context(request: @request), other)
    assert_match(/issue_landing_prompt wrote review\.released/, audit(after).sole)
  end

  test "a New prompt receipt does not excuse a second Working task's release" do
    # A seat holds one task (tasks.holder_seat_id is unique), so one
    # command released one: the second release is the first, copied onto
    # a task the seat built earlier.
    earlier = @scenario.task(state: "working", builder: @seat)
    Leverage::SeatRuns.release_working_task(@scenario.context, @seat, reason: "seat_disabled")
    task = @scenario.task(state: "working", builder: @seat)
    released = Leverage::SeatRuns.release_working_task(@scenario.context(request: @request), @seat, reason: "new_prompt")
    second = released.dup.tap { |event| event.assign_attributes(task_id: earlier.id, seq: released.seq + 1) }
    states = { task.id => "working", earlier.id => "working" }

    assert Leverage::LogAudit.historical_prompt_release?([ released ], states, receipt: @command)
    assert Leverage::LogAudit.historical_prompt_release?([ second ], states, receipt: @command)
    refute Leverage::LogAudit.historical_prompt_release?([ released, second ], states, receipt: @command)
  end

  test "a New prompt receipt does not excuse a hold on another seat's Finishing task" do
    other = @scenario.seat(role: "general")
    theirs = @scenario.finishing_task(builder: other, actions: [ { kind: "send", description: "Send the sample.", state: "approved" } ])
    mine = @scenario.finishing_task(builder: @seat, actions: [ { kind: "send", description: "Send the sample.", state: "approved" } ])
    review = @scenario.review(@scenario.task(state: "in_review"), reviewer: @seat)
    after = @scenario.workspace.reload.last_seq
    ctx = @scenario.context(request: @request)
    Leverage::Finishing.lose_builder(ctx, mine, cause: nil)
    Leverage::SeatRuns.release_held_reviews(ctx, @seat)
    assert_equal %w[hold.opened inbox.opened review.released], key_events.map(&:type)
    states = { mine.id => "finishing", theirs.id => "finishing", review.task_id => "in_review" }
    assert Leverage::LogAudit.historical_prompt_release?(key_events, states, receipt: @command)

    Leverage::Finishing.lose_builder(ctx, theirs, cause: nil)
    assert_equal %w[hold.opened inbox.opened review.released hold.opened inbox.opened], key_events.map(&:type)
    refute Leverage::LogAudit.historical_prompt_release?(key_events, states, receipt: @command)
  end

  test "after key retention the old reason does not excuse the release of another seat's review" do
    @command.destroy!
    other = @scenario.seat(role: "general")
    task = @scenario.task(state: "working", builder: @seat)
    review = @scenario.review(@scenario.task(state: "in_review"), reviewer: other)
    ctx = @scenario.context(request: @request)
    Leverage::SeatRuns.release_working_task(ctx, @seat, reason: "new_prompt")
    states = { task.id => "working", review.task_id => "in_review" }
    assert Leverage::LogAudit.historical_prompt_release?(key_events, states, receipt: nil)

    Leverage::SeatRuns.release_held_reviews(ctx, other)
    assert_equal %w[task.released review.released], key_events.map(&:type)
    refute Leverage::LogAudit.historical_prompt_release?(key_events, states, receipt: nil)
  end

  # A provisional claim another seat has waiting on a Ready task, with its
  # task.before_claim check about that seat.
  def provisional_claim(seat)
    task = @scenario.task(state: "ready")
    pending = @scenario.pending_transition(task, command: "claim", requester: seat)
    task.update!(holder_seat_id: seat.id)
    @scenario.rule_check(task, rule: @scenario.rule(hook: "task.before_claim"), subject: seat, pending: pending)
    task
  end

  test "a New prompt receipt does not excuse the withdrawal of another seat's provisional claim" do
    other = @scenario.seat(role: "general")
    claimed = provisional_claim(other)
    review = @scenario.review(@scenario.task(state: "in_review"), reviewer: @seat)
    after = @scenario.workspace.reload.last_seq
    ctx = @scenario.context(request: @request)
    Leverage::SeatRuns.cancel_provisional_claim(ctx, other)
    Leverage::SeatRuns.release_held_reviews(ctx, @seat)

    assert_equal %w[check.finished job.withdrawn review.released], key_events.map(&:type)
    states = { claimed.id => "ready", review.task_id => "in_review" }
    refute Leverage::LogAudit.historical_prompt_release?(key_events, states, receipt: @command)
    assert_match(/command #{@request.key} .*issue_landing_prompt wrote/, audit(after).sole)
  end

  test "after key retention the old reason does not excuse the withdrawal of another seat's provisional claim" do
    @command.destroy!
    other = @scenario.seat(role: "general")
    claimed = provisional_claim(other)
    task = @scenario.task(state: "working", builder: @seat)
    after = @scenario.workspace.reload.last_seq
    ctx = @scenario.context(request: @request)
    Leverage::SeatRuns.cancel_provisional_claim(ctx, other)
    Leverage::SeatRuns.release_working_task(ctx, @seat, reason: "new_prompt")

    assert_equal %w[check.finished job.withdrawn task.released], key_events.map(&:type)
    states = { claimed.id => "ready", task.id => "working" }
    refute Leverage::LogAudit.historical_prompt_release?(key_events, states, receipt: nil)
    assert audit(after).any? { |line| line.include?(@request.key) }, audit(after).inspect
  end

  test "a New prompt receipt does not excuse the release of a review the seat no longer held" do
    # The seat started the review and lost it before the New prompt, so
    # the release under the key is not of a review it holds.
    review = @scenario.review(@scenario.task(state: "in_review"), reviewer: @seat)
    Leverage::SeatRuns.release_held_reviews(@scenario.context, @seat)
    after = @scenario.workspace.reload.last_seq
    released = Leverage::SeatRuns.release_review(@scenario.context(request: @request), review)

    assert_equal [ "review.released", "owner", @request.key ], [ released.type, released.actor_kind, released.command_id ]
    refute Leverage::LogAudit.historical_prompt_release?([ released ], { review.task_id => "in_review" }, receipt: @command)
    assert_match(/issue_landing_prompt wrote review\.released/, audit(after).sole)
  end

  test "a New prompt that released a Working task leased again after a failed review passes the audit" do
    # The seat's latest builder lease came from review.failed's
    # lease_seat_id, not from a claim (Leases.builder_grantee).
    task = @scenario.task(state: "in_review", builder: @seat)
    review = @scenario.review(task)
    review.update!(verdict: "failed", lease_due_at: nil)
    task.update!(state: "working", holder_seat_id: @seat.id, lease_due_at: @scenario.database_now + 3600)
    grant = @scenario.append("review.failed", task: task, subject: review, actor_kind: "seat", actor_id: review.reviewer_seat_id,
      payload: { failed_criterion_ids: [], failed_rule_check_id: nil, lease_seat_id: @seat.id, wait_cause: nil })
    after = @scenario.workspace.reload.last_seq
    released = Leverage::SeatRuns.release_working_task(@scenario.context(request: @request), @seat, reason: "new_prompt")

    assert_equal task.id, released.task_id
    assert_equal grant.id, Event.where(task_id: task.id).where("seq < ?", released.seq)
      .where("type = 'task.claimed' OR payload->>'lease_seat_id' IS NOT NULL").order(:seq).last.id
    assert_empty audit(after)
    @command.destroy!
    assert_empty audit(after)
  end

  test "a release cannot excuse an orphan job withdrawal on an unrelated task after key retention" do
    @command.destroy!
    task = @scenario.task(state: "backlog")
    job = @scenario.job(kind: "contract_draft", task: task)
    @scenario.task(state: "working", builder: @seat)
    after = @scenario.workspace.reload.last_seq
    ctx = @scenario.context(request: @request)
    Leverage::SeatRuns.release_working_task(ctx, @seat, reason: "new_prompt")
    orphan = Leverage::Jobs.withdraw(ctx, job)
    refute Leverage::LogAudit.historical_prompt_release?([ orphan ], { task.id => "backlog" }, receipt: nil)
    findings = Leverage::LogAudit.call(@scenario.workspace_id, after_seq: after)
    assert findings.any? { |line| line.include?(@request.key) }, findings.inspect
  end

  test "New prompt could withdraw a provisional claim before it got a lease" do
    task = @scenario.task(state: "ready")
    pending = @scenario.pending_transition(task, command: "claim", requester: @seat)
    task.update!(holder_seat_id: @seat.id)
    @scenario.rule_check(task, rule: @scenario.rule(hook: "task.before_claim"), subject: @seat, pending: pending)
    after = @scenario.workspace.reload.last_seq
    Leverage::SeatRuns.cancel_provisional_claim(@scenario.context(request: @request), @seat)
    events = Event.where(workspace_id: @scenario.workspace_id, command_id: @request.key).order(:seq)
    assert_equal %w[check.finished job.withdrawn], events.pluck(:type)
    assert_empty Leverage::LogAudit.call(@scenario.workspace_id, after_seq: after)
    @command.destroy!
    assert_empty Leverage::LogAudit.call(@scenario.workspace_id, after_seq: after)
  end

  test "a New prompt that released a review and withdrew a provisional claim passes the audit" do
    review = @scenario.review(@scenario.task(state: "in_review"), reviewer: @seat)
    task = @scenario.task(state: "ready")
    pending = @scenario.pending_transition(task, command: "claim", requester: @seat)
    task.update!(holder_seat_id: @seat.id)
    @scenario.rule_check(task, rule: @scenario.rule(hook: "task.before_claim"), subject: @seat, pending: pending)
    after = @scenario.workspace.reload.last_seq
    ctx = @scenario.context(request: @request)
    Leverage::SeatRuns.cancel_provisional_claim(ctx, @seat)
    Leverage::SeatRuns.release_held_reviews(ctx, @seat)

    assert_equal %w[check.finished job.withdrawn review.released], key_events.map(&:type)
    assert_equal [ task.id, task.id, review.task_id ], key_events.map(&:task_id)
    states = { task.id => "ready", review.task_id => "in_review" }
    assert Leverage::LogAudit.historical_prompt_release?(key_events, states, receipt: @command)
    assert_empty audit(after)

    # The claim is the receipt's seat's, on a Ready task, and its own check.
    another = @command.dup.tap { |row| row.result = row.result.merge("seat_id" => @scenario.seat(role: "general").id) }
    refute Leverage::LogAudit.historical_prompt_release?(key_events, states, receipt: another)
    refute Leverage::LogAudit.historical_prompt_release?(key_events, states.merge(task.id => "working"), receipt: @command)
    withdrawal = key_events.first
    of_another = withdrawal.dup.tap { |event| event.payload = withdrawal.payload.merge("subject_id" => SecureRandom.uuid) }
    of_another.seq = withdrawal.seq
    refute Leverage::LogAudit.historical_prompt_release?([ of_another, *key_events.drop(1) ], states, receipt: @command)
  end

  test "a task released because its seat was removed is still flagged under New prompt" do
    @scenario.task(state: "working", builder: @seat)
    after = @scenario.workspace.reload.last_seq
    Leverage::SeatRuns.release_working_task(@scenario.context(request: @request), @seat, reason: "seat_removed")
    assert_match(/issue_landing_prompt.*task\.released/, Leverage::LogAudit.call(@scenario.workspace_id, after_seq: after).sole)
  end
end
