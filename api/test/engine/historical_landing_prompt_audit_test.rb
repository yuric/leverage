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

  test "a New prompt that released its Working task passes the audit" do
    task = @scenario.task(state: "working", builder: @seat)
    @scenario.hold(task, reason: "seat_paused")
    after = @scenario.workspace.reload.last_seq
    ctx = @scenario.context(request: @request)
    released = Leverage::SeatRuns.release_working_task(ctx, @seat, reason: "new_prompt")
    assert_equal [ task.id, "new_prompt", @request.key ], [ released.task_id, released.payload["reason"], released.command_id ]
    events = Event.where(workspace_id: @scenario.workspace_id, command_id: @request.key).order(:seq)
    assert_equal %w[task.released hold.closed], events.pluck(:type)
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

  test "a task released because its seat was removed is still flagged under New prompt" do
    @scenario.task(state: "working", builder: @seat)
    after = @scenario.workspace.reload.last_seq
    Leverage::SeatRuns.release_working_task(@scenario.context(request: @request), @seat, reason: "seat_removed")
    assert_match(/issue_landing_prompt.*task\.released/, Leverage::LogAudit.call(@scenario.workspace_id, after_seq: after).sole)
  end
end
