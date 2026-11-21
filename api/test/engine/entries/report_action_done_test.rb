require "test_helper"
require_relative "request_action_test"

class ReportActionDoneTest < ActiveSupport::TestCase
  include OutwardActionCommands

  test "retrying the final report keeps one completion and returns the stored outcome" do
    @scenario = Scenario.new
    @builder = @scenario.seat
    task, action = finishing_action("approved")
    assert acknowledge(task).completed?
    request = action_request("report_action_done", caller: @builder, id: task.id, aid: action.id)

    2.times { assert T.apply(request).completed? }
    assert_equal [ "done", "done" ], [ action.reload.state, task.reload.state ]
    assert_nil task.lease_due_at
    assert_equal %w[action.reported_done task.done], Event.where(command_id: request.key).order(:seq).pluck(:type)
  end
end
