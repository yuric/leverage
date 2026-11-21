require "test_helper"
require_relative "request_action_test"

class ApproveActionTest < ActiveSupport::TestCase
  include OutwardActionCommands

  test "retrying owner approval preserves the original approval and lease" do
    @scenario = Scenario.new
    @builder = @scenario.seat
    task, action = finishing_action("requested")
    hold = Leverage::Holds.open(@scenario.context, task: task, reason: "owner_approval", action_id: action.id,
      facts: { action_id: action.id })
    request = action_request("approve_action", caller: @scenario.owner, id: action.id)

    assert T.apply(request).completed?
    due = task.reload.lease_due_at
    assert T.apply(request).completed?
    assert_equal due, task.reload.lease_due_at
    assert_equal [ "owner", @scenario.owner.id ], action.reload.attributes.values_at("approved_by_kind", "approved_by_id")
    assert hold.reload.closed_at
    assert_equal %w[action.approved hold.closed inbox.resolved], Event.where(command_id: request.key).order(:seq).pluck(:type)
  end
end
