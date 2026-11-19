require "test_helper"

# Leverage::Holds (PRD L121, L150-L201; registry hold_reasons; milestone 2
# plan WP4, EN-13, EN-31; contract decisions DB-20, DB-35): a hold row with
# hold.opened and its Needs you item; a hold whose reason pauses the lease
# clock pauses both the builder's lease on the task and the reviewer's on
# its open review, and a lease granted while it is open starts paused;
# closing the last pausing hold restarts both clocks from the command's time
# with the time they had left, and the last hold on a task a seat holds
# sets tasks.resume_pending_since.
class HoldsTest < ActiveSupport::TestCase
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
end
