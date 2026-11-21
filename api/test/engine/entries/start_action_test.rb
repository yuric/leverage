require "test_helper"
require_relative "request_action_test"

class StartActionTest < ActiveSupport::TestCase
  include OutwardActionCommands

  test "an announced action is written once, and another task's action is not found" do
    @scenario = Scenario.new
    @builder = @scenario.seat
    task, action = finishing_action("approved")
    _other_task, other_action = finishing_action("approved", builder: @scenario.seat)
    assert acknowledge(task).completed?

    request = action_request("start_action", caller: @builder, id: task.id, aid: action.id)
    2.times { assert T.apply(request).completed? }
    assert_equal "started", action.reload.state
    assert_equal [ "action.started" ], Event.where(command_id: request.key).pluck(:type)

    wrong = action_request("start_action", caller: @builder, id: task.id, aid: other_action.id)
    assert_raises(T::NotFound) { T.apply(wrong) }
    assert_equal "approved", other_action.reload.state
  end
end
