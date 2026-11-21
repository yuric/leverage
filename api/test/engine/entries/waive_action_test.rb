require "test_helper"
require_relative "rule_support"

class WaiveActionTest < ActiveSupport::TestCase
  include RuleSupport

  setup { use_scenario }

  test "passes only the named action to the writer that withdraws its running checks" do
    task = scenario.finishing_task(actions: [
      { state: "requested", description: "First made-up action." },
      { state: "requested", description: "Second made-up action." }
    ])
    action, other = Action.where(task_id: task.id).order(:position).to_a
    hold = scenario.hold(task, reason: "owner_approval", facts: { action_id: action.id })
    unrelated = scenario.hold(task, reason: "owner_approval", facts: { action_id: other.id })
    rule = scenario.rule(hook: "action.requested")
    check = scenario.rule_check(task, rule: rule, hook: "action.requested", subject: action)
    other_check = scenario.rule_check(task, rule: rule, hook: "action.requested", subject: other)

    waive = lambda do |ctx, target|
      if target == action
        job = Leverage::RuleChecks.open_job(check)
        Leverage::RuleChecks.withdraw(ctx, check)
        Leverage::Jobs.withdraw(ctx, job)
      end
      :waived
    end
    calls = recording({ Leverage::Actions => %i[waive last_open?], Leverage::Finishing => %i[settle after_command] },
      fakes: { "Actions.waive" => waive, "Actions.last_open?" => ->(_action) { false },
               "Finishing.settle" => ->(*) { }, "Finishing.after_command" => ->(*) { } }) do
      assert_completed owner_command("waive_action", { "id" => action.id })
    end

    ctx, target = calls.fetch("Actions.waive").sole.arguments
    assert_equal [ "waive_action", action.id ], [ ctx.request.command, target.id ]
    assert_equal "withdrawn", check.reload.result
    assert_equal "withdrawn", Job.find(RuleCheckAttempt.find_by!(rule_check_id: check.id).job_id).state
    assert_nil other_check.reload.result
    assert_equal "requested", other.reload.state
    assert hold.reload.closed_at
    assert_nil unrelated.reload.closed_at
    assert_equal "waive", Event.where(task_id: task.id, type: "inbox.resolved").sole.payload.fetch("choice")
  end

  test "refuses a previously waived action" do
    task = scenario.finishing_task(actions: [ { state: "waived", description: "Made-up action." } ])
    action = Action.find_by!(task_id: task.id)

    assert_empty events_written {
      assert_refused "invalid_state", owner_command("waive_action", { "id" => action.id })
    }
  end
end
