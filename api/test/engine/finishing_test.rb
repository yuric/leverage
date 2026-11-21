require "test_helper"

class FinishingTest < ActiveSupport::TestCase
  F = Leverage::Finishing

  setup do
    @scenario = Scenario.new
    @builder = @scenario.seat(role: "builder")
  end

  test "after command grants the oldest completing approval and leaves the next waiting" do
    first = waiting_task
    second = waiting_task
    ctx = @scenario.context
    F.after_command(ctx)
    assert_equal @builder.id, first.reload.holder_seat_id
    assert_nil second.reload.holder_seat_id
    event = ctx.events.find { |written| written.type == "action.lease_granted" }
    assert_equal @builder.id, event&.payload&.fetch("lease_seat_id")
    assert_equal first.id, event.task_id
  end

  test "a managed builder gets an action lease only once an account is available" do
    credential = @scenario.credential(provider: "claude")
    @builder.update!(credential_id: credential.id)
    credential.update!(limited_since: @scenario.database_now, limited_until: @scenario.database_now + 1.hour)
    task = waiting_task
    F.after_command(@scenario.context)
    assert_nil task.reload.holder_seat_id

    credential.update!(limited_until: @scenario.database_now - 1.second)
    F.after_command(@scenario.context)
    assert_equal @builder.id, task.reload.holder_seat_id
  end

  test "a holder qualifies only while enabled and unpaused" do
    task = @scenario.finishing_task(builder: @builder, actions: [ { kind: "send", state: "approved" } ])
    assert F.builder_holds_task?(task)
    @builder.update!(paused: true)
    refute F.builder_holds_task?(task)
    @builder.update!(paused: false, enabled: false)
    refute F.builder_holds_task?(task)
  end

  test "settle leaves a holder's lease alone and holds a task whose builder is disabled" do
    task = @scenario.finishing_task(builder: @builder, actions: [ { kind: "send", state: "approved" } ])
    due = task.lease_due_at
    ctx = @scenario.context
    F.settle(ctx, task, by: nil)
    assert_equal due, task.reload.lease_due_at
    assert_empty ctx.events

    task.update!(holder_seat_id: nil, lease_due_at: nil)
    @builder.update!(enabled: false)
    F.settle(ctx, task, by: nil)
    assert_equal [ "action_unconfirmed" ], Leverage::Holds.open_holds(task).map(&:reason)
  end

  test "a close carrying a lease replaces the holder's earlier lease" do
    task = @scenario.finishing_task(builder: @builder, actions: [ { kind: "send", state: "approved" } ])
    ctx = @scenario.context
    hold = F.lose_builder(ctx, task, cause: nil)
    Leverage::Holds.close(ctx, hold: hold, task: task, lease_seat_id: @builder.id) do |event|
      F.settle(ctx, task, by: event)
    end
    assert_equal @builder.id, task.reload.holder_seat_id
    assert_in_delta ctx.at + ctx.workspace.lease_length_seconds, task.lease_due_at, 0.000001
    assert_nil task.resume_pending_since
  end

  private

  def waiting_task
    @scenario.finishing_task(builder: @builder, holder: false, actions: [ { kind: "send", state: "approved" } ])
  end
end
