require "test_helper"

module OutwardActionCommands
  T = Leverage::Transitions

  def finishing_action(state, holder: nil, scenario: @scenario, builder: @builder)
    task = scenario.finishing_task(builder: builder, holder: holder,
      actions: [ { state: state, description: "Publish the made-up sample." } ])
    [ task, Action.find_by!(task_id: task.id) ]
  end

  def action_request(command, caller: nil, **params)
    caller_kind = caller.is_a?(User) ? "owner" : ("seat" if caller)
    T::Request.new(command: command, workspace_id: @scenario.workspace_id, caller_kind: caller_kind,
      caller_id: caller&.id, key: ("key-#{SecureRandom.hex(6)}" if caller),
      request_hash: Digest::SHA256.hexdigest(params.to_json), params: params)
  end

  def acknowledge(task)
    hash = Leverage::Briefing.hash_for(task, seat: @builder)
    T.apply(action_request("acknowledge_briefing", caller: @builder, id: task.id, briefing_hash: hash))
  end
end

class RequestActionTest < ActiveSupport::TestCase
  include OutwardActionCommands

  test "the app cannot request an action in a different workspace" do
    @scenario = Scenario.new
    other = Scenario.new
    _task, action = finishing_action("requested", scenario: other, builder: other.seat)

    assert_raises(T::NotFound) { T.apply(action_request("request_action", id: action.id)) }
    assert_empty Hold.where(action_id: action.id)
  end
end
