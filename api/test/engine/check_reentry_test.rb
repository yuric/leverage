require "test_helper"
require_relative "entries/call_spy"

class CheckReentryTest < ActiveSupport::TestCase
  include CallSpy

  setup { @scenario = Scenario.new }

  test "a settled check completes the same pending command under its original key" do
    task = @scenario.task(state: "backlog")
    params = { "id" => task.id, "goal" => "Made-up goal.",
               "criteria" => [ { "text" => "Made-up review criterion.", "kind" => "review" } ], "actions" => [] }
    pending = @scenario.pending_transition(task, command: "complete_contract", requester: @scenario.owner, params: params)
    rule = @scenario.rule(hook: "task.before_ready")
    check = @scenario.rule_check(task, rule: rule, pending: pending, result: "passed")
    Leverage::Gating.implementation = Leverage::Gating::StandIn.new(
      transitions: { pending.id => { checks: [] } })
    ctx = @scenario.context

    decision = Leverage::CheckReentry.after(ctx, check, trigger(:check_finished, check))

    assert_equal :complete, decision&.action
    assert_equal [ "completed", "ready" ], [ pending.reload.state, task.reload.state ]
    assert_equal [ pending.command_key ], ctx.events.map(&:command_id).uniq
  end

  test "an action check re-enters that action with the same timer trigger" do
    task = @scenario.finishing_task
    action = Action.create!(workspace_id: task.workspace_id, task_id: task.id, position: 1, kind: "send", state: "requested")
    rule = @scenario.rule(hook: "action.requested", checker: "app")
    check = @scenario.rule_check(task, rule: rule, subject: action, result: "error")
    ctx = @scenario.context
    timed_out = trigger(:check_timed_out, check)

    assert_respond_to Leverage::Finishing, :reenter_action
    calls = spy_on(Leverage::Finishing, :reenter_action) { Leverage::CheckReentry.after(ctx, check, timed_out) }

    assert_equal [ [ ctx, action, timed_out ] ], calls.map(&:arguments)
  end

  test "a check of a completed transition does not re-enter it" do
    task = @scenario.task(state: "backlog")
    pending = @scenario.pending_transition(task, command: "complete_contract", requester: @scenario.owner, state: "completed")
    check = @scenario.rule_check(task, rule: @scenario.rule(hook: "task.before_ready"), pending: pending, result: "passed")

    calls = spy_on(Leverage::PendingTransitions, :reenter) do
      Leverage::CheckReentry.after(@scenario.context, check, trigger(:check_finished, check))
    end

    assert_empty calls
  end

  private

  def trigger(kind, check) = Leverage::Gating::Trigger.new(kind: kind, rule_check_id: check.id)
end
