require "test_helper"

# Timers run first (PRD L118-L120, test 7 at L842, L913; milestone 2 plan
# EN-14, EN-16, EN-17, EN-18): before a command, every timer already due on
# its target task and on every task or review the calling seat holds is
# applied in the same transaction, with the due time as effective_at, the
# app as actor, no command_id, and seq before the command's own events.
# The seat's call is then refused lease_expired, and the refusal commits
# the timer's events with its commands row: no sweep has run.
#
# The seat commands here are entries defined in this file (the real ones
# are WP3's): they refuse a seat that no longer holds the task the way
# EN-15 says, through Leases.ended_by_expiry?.
module TimerTestEntries
  T = Leverage::Transitions

  # A builder's call on a task: path id is the task.
  class TaskCall < Leverage::Transitions::Entry
    def load(ctx)
      @task = Task.find_by!(id: ctx.request.params.fetch("id"), workspace_id: ctx.workspace.id)
    end

    def refusals(ctx)
      return [] if @task.holder_seat_id == ctx.request.caller_id

      [ Leverage::Leases.ended_by_expiry?(@task, ctx.request.caller_id) ? "lease_expired" : "not_holder" ]
    end

    def perform(ctx)
      Leverage::Leases.renew(ctx, @task)
      ctx.emit("cost.reported", task: @task, payload: { tokens: 1, spend: 0.01 })
      @result = { "task_id" => @task.id }
    end
  end

  # A reviewer's call on a review: path id is the review.
  class ReviewCall < Leverage::Transitions::Entry
    def load(ctx)
      @review = Review.find_by!(id: ctx.request.params.fetch("id"), workspace_id: ctx.workspace.id)
    end

    def refusals(ctx)
      return [] if @review.reviewer_seat_id == ctx.request.caller_id

      [ Leverage::Leases.ended_by_expiry?(@review, ctx.request.caller_id) ? "lease_expired" : "not_holder" ]
    end

    def perform(ctx)
      Leverage::Leases.renew(ctx, @review)
      @result = { "review_id" => @review.id }
    end
  end

  # A seat's call that names no task (a claim): only what the seat holds is
  # looked at.
  class Untargeted < Leverage::Transitions::Entry
    def perform(_ctx) = @result = {}
  end
end

class TimersDueTest < CommittingTestCase
  T = Leverage::Transitions
  E = TimerTestEntries

  setup do
    scenario.workspace.update!(lease_length_seconds: 600)
    @builder = scenario.seat(role: "builder")
    @reviewer = scenario.seat(role: "reviewer")
  end

  def request(command, seat, key, params = {})
    T::Request.new(command: command, workspace_id: scenario.workspace_id, caller_kind: "seat", caller_id: seat.id,
      key: key, request_hash: "hash-#{key}", params: params)
  end

  def apply(command, seat, key, params = {}, entry: E::TaskCall)
    T::Table.with_entries(command => entry) { T.apply(request(command, seat, key, params)) }
  end

  def events_after(seq)
    Event.where(workspace_id: scenario.workspace_id).where("seq > ?", seq).order(:seq).to_a
  end

  def last_seq = Workspace.find(scenario.workspace_id).last_seq

  test "test 7: a call after the due time is refused lease_expired, and the expiry commits at the due time" do
    task = scenario.task(state: "working", builder: @builder)
    criterion = Criterion.find_by!(task_id: task.id, kind: "build")
    # The due time comes after every event the task has (effective times
    # never go backwards, L120) and before the command's time.
    due = scenario.database_now
    scenario.make_due(task, at: due)
    before = last_seq

    outcome = apply("pass_criterion", @builder, "late-pass", { "id" => task.id, "cid" => criterion.id })

    assert outcome.refused?
    assert_equal "lease_expired", outcome.refusal.code
    events = events_after(before)
    assert_equal [ "task.lease_expired" ], events.map(&:type), "the timer's event committed; the call wrote none"
    expired = events.first
    assert_in_delta due.to_f, expired.effective_at.to_f, 0.000_001, "recorded at the due time"
    assert_operator expired.at, :>, expired.effective_at
    assert_equal [ "app", nil, nil ], [ expired.actor_kind, expired.actor_id, expired.command_id ]
    assert_equal({ "wait_cause" => nil }, expired.payload)
    assert_equal task.id, expired.task_id

    task.reload
    assert_equal [ "ready", nil, nil ], [ task.state, task.holder_seat_id, task.lease_due_at ]
    assert_nil task.builder_seat_id, "back in Ready, the task has no builder (PRD, What the replay test rebuilds)"

    row = Command.find_by!(caller_kind: "seat", caller_id: @builder.id, key: "late-pass")
    assert_equal "refused", row.outcome
    assert_equal "lease_expired", row.refusal.fetch("code")
  end

  test "a repeat of the refused call is answered from its row and writes nothing" do
    task = scenario.task(state: "working", builder: @builder)
    scenario.make_due(task)
    first = apply("heartbeat", @builder, "hb-1", { "id" => task.id })
    after_first = last_seq

    again = apply("heartbeat", @builder, "hb-1", { "id" => task.id })

    assert_equal first.refusal, again.refusal
    assert_equal after_first, last_seq
  end

  test "a heartbeat after the due time is refused and does not renew the lease" do
    task = scenario.task(state: "working", builder: @builder)
    scenario.make_due(task)

    outcome = apply("heartbeat", @builder, "hb-late", { "id" => task.id })

    assert_equal "lease_expired", outcome.refusal&.code
    task.reload
    assert_nil task.lease_due_at
    assert_equal "ready", task.state
  end

  test "a call before the due time runs no timer" do
    task = scenario.task(state: "working", builder: @builder)
    before = last_seq

    outcome = apply("heartbeat", @builder, "hb-early", { "id" => task.id })

    assert outcome.completed?
    assert_equal [ "cost.reported" ], events_after(before).map(&:type)
    assert_equal "working", task.reload.state
  end

  test "a paused lease does not end, however far past its due column" do
    task = scenario.task(state: "working", builder: @builder)
    task.update_columns(lease_due_at: scenario.database_now - 3600, lease_time_left_while_paused: 300)
    before = last_seq

    outcome = apply("heartbeat", @builder, "hb-paused", { "id" => task.id })

    assert outcome.completed?
    refute_includes events_after(before).map(&:type), "task.lease_expired"
    assert_equal "working", task.reload.state
  end

  test "the timer's events come first in seq and share the command's at" do
    task = scenario.task(state: "working", builder: @builder)
    scenario.make_due(task)
    other = scenario.seat(role: "builder")
    before = last_seq

    # Another builder's call on the task: the task's timer runs first, then
    # the call is refused (the other seat never held it).
    outcome = apply("heartbeat", other, "hb-other", { "id" => task.id })

    assert_equal "not_holder", outcome.refusal&.code
    events = events_after(before)
    assert_equal [ "task.lease_expired" ], events.map(&:type)
    assert_equal before + 1, events.first.seq
  end

  test "a timer on a task the seat holds runs before a call that names no task" do
    task = scenario.task(state: "working", builder: @builder)
    scenario.make_due(task)
    before = last_seq

    outcome = apply("claim", @builder, "claim-1", {}, entry: E::Untargeted)

    assert outcome.completed?
    assert_equal [ "task.lease_expired" ], events_after(before).map(&:type)
    assert_equal "ready", task.reload.state
  end

  test "a reviewer's call after its review lease's due time is refused lease_expired; the task stays In review" do
    task = scenario.task(state: "in_review", builder: @builder)
    review = scenario.review(task, reviewer: @reviewer)
    due = scenario.database_now
    scenario.make_due(review, at: due)
    before = last_seq

    outcome = apply("heartbeat_review", @reviewer, "hbr-late", { "id" => review.id }, entry: E::ReviewCall)

    assert_equal "lease_expired", outcome.refusal&.code
    events = events_after(before)
    assert_equal [ "review.lease_expired" ], events.map(&:type)
    expired = events.first
    assert_in_delta due.to_f, expired.effective_at.to_f, 0.000_001
    assert_equal [ "review", review.id, task.id ], [ expired.subject_kind, expired.subject_id, expired.task_id ]
    assert_equal({}, expired.payload)
    review.reload
    assert_nil review.reviewer_seat_id, "unassigned, so another reviewer can claim it (L121)"
    assert_nil review.lease_due_at
    assert_equal "in_review", task.reload.state
  end

  test "a review the seat holds is expired before a call that names no review" do
    task = scenario.task(state: "in_review", builder: @builder)
    review = scenario.review(task, reviewer: @reviewer)
    scenario.make_due(review)
    before = last_seq

    apply("claim_review", @reviewer, "claim-review-1", {}, entry: E::Untargeted)

    assert_equal [ "review.lease_expired" ], events_after(before).map(&:type)
  end

  test "an owner's command on a task applies the task's due timer first" do
    task = scenario.task(state: "working", builder: @builder)
    scenario.make_due(task)
    before = last_seq
    owner_request = T::Request.new(command: "cancel", workspace_id: scenario.workspace_id, caller_kind: "owner",
      caller_id: scenario.owner.id, key: "cancel-1", request_hash: "hash-cancel-1", params: { "id" => task.id })

    T::Table.with_entries("cancel" => E::Untargeted) { T.apply(owner_request) }

    assert_equal [ "task.lease_expired" ], events_after(before).map(&:type)
  end

  test "a timer on another seat's task that the call does not name is left to the sweep" do
    task = scenario.task(state: "working", builder: @builder)
    scenario.make_due(task)
    other = scenario.seat(role: "builder")
    before = last_seq

    apply("claim", other, "claim-other", {}, entry: E::Untargeted)

    assert_empty events_after(before)
    assert_equal "working", task.reload.state
  end

  test "effective times never go backwards within a task" do
    task = scenario.task(state: "working", builder: @builder)
    latest = Event.where(task_id: task.id).maximum(:effective_at)
    # A due time earlier than an event the task already has: the expiry is
    # recorded at that event's time, not before it.
    scenario.make_due(task, at: latest - 60)
    before = last_seq

    apply("heartbeat", @builder, "hb-backwards", { "id" => task.id })

    expired = events_after(before).first
    assert_equal "task.lease_expired", expired.type
    assert_in_delta latest.to_f, expired.effective_at.to_f, 0.000_001
  end

  test "apply_due returns the events it wrote and leaves a timer's own command alone" do
    task = scenario.task(state: "working", builder: @builder)
    scenario.make_due(task)

    written = ActiveRecord::Base.transaction do
      ctx = scenario.context(request: request("heartbeat", @builder, "direct", { "id" => task.id }))
      Leverage::Timers.apply_due(ctx)
    end
    assert_equal [ "task.lease_expired" ], written.map(&:type)

    task2 = scenario.task(state: "working", builder: scenario.seat(role: "builder"))
    scenario.make_due(task2)
    timer_request = T::Request.new(command: "builder_lease_expiry", workspace_id: scenario.workspace_id,
      caller_kind: nil, caller_id: nil, key: nil, request_hash: nil, params: { "task_id" => task2.id })
    none = ActiveRecord::Base.transaction do
      Leverage::Timers.apply_due(scenario.context(request: timer_request))
    end
    assert_empty none, "the timer command applies itself; apply_due adds nothing"
  end
end
