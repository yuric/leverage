require "test_helper"
require_relative "rule_support"

class OverturnApprovalTest < ActiveSupport::TestCase
  include RuleSupport

  setup do
    use_scenario
    @orchestrator = scenario.seat(role: "orchestrator")
  end

  test "overturning an approved or started action delegates the stop as the owner" do
    %w[approved started].each do |state|
      task, action = action_on(state)

      calls = recording({ Leverage::Actions => :stop, Leverage::Finishing => :settle },
        fakes: { "Actions.stop" => ->(_ctx, _action, by:) { nil } }) do
        assert_empty events_written { assert_completed(overturn(action)) }, "the stop seam owns the writes"
      end

      stop = calls.fetch("Actions.stop").sole
      assert_equal action.id, stop.arguments.fetch(1).id
      assert_equal [ "owner", scenario.owner.id ], stop.keywords.fetch(:by)
      assert_empty calls.fetch("Finishing.settle")
      assert_equal "finishing", task.reload.state
    end
  end

  test "records one overturn of a done action and reuses the original result on same-key retry" do
    task, action = action_on("done")
    ActiveRecord::Base.transaction(requires_new: true) do
      ctx = scenario.context
      task.update!(state: "done")
      ctx.emit("task.done", task: task, payload: {})
    end

    key = new_key
    record = ->(ctx, recorded) { ctx.emit("action.overturn_recorded", task: task, subject: recorded, payload: {}) }
    calls = recording({ Leverage::Actions => :record_overturn }, fakes: { "Actions.record_overturn" => record }) do
      event = events_written { assert_completed(overturn(action, key: key)) }.sole
      assert_equal "action.overturn_recorded", event.type
      assert_equal task.id, event.task_id
      assert_equal "action", event.subject_kind
      assert_equal action.id, event.subject_id
      assert_equal "owner", event.actor_kind
      assert_equal scenario.owner.id, event.actor_id
      assert_equal key, event.command_id
      assert_equal({}, event.payload)

      assert_empty events_written { assert_completed(overturn(action, key: key)) }
      assert_empty events_written { assert_refused("invalid_state", overturn(action)) }
    end

    assert_equal action.id, calls.fetch("Actions.record_overturn").sole.arguments.fetch(1).id
    assert_equal "done", action.reload.state
    assert_equal "done", task.reload.state
  end

  test "refuses owner approvals and actions outside the approved, started and done states" do
    _, owner_approved = action_on("approved", by: scenario.owner)
    _, stopped = action_on("stopped")

    [ owner_approved, stopped ].each do |action|
      calls = recording({ Leverage::Actions => %i[stop record_overturn] }) do
        assert_empty events_written { assert_refused("invalid_state", overturn(action)) }
      end
      assert_empty calls.fetch("Actions.stop")
      assert_empty calls.fetch("Actions.record_overturn")
    end
  end

  test "an outward action from another workspace is not found" do
    other = Scenario.new
    task = other.finishing_task(
      actions: [ { kind: "publish", description: "Publish the made-up page.", state: "approved" } ])
    action = Action.find_by!(task_id: task.id)

    assert_raises(T::NotFound) { overturn(action) }
  end

  private

  def action_on(state, by: @orchestrator)
    task = scenario.finishing_task(holder: false,
      actions: [ { kind: "publish", description: "Publish the made-up page.", state: state } ])
    action = Action.find_by!(task_id: task.id)
    action.update!(approved_by_kind: (by.is_a?(Seat) ? "seat" : "owner"), approved_by_id: by.id)
    [ task, action ]
  end

  def overturn(action, **options)
    owner_command("overturn_approval", { "id" => action.id }, **options)
  end
end
