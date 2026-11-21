require "test_helper"
require_relative "request_action_test"

class GrantActionLeaseTest < ActiveSupport::TestCase
  include OutwardActionCommands

  test "granting a lease keeps the approval and starts no check" do
    @scenario = Scenario.new
    @builder = @scenario.seat
    task, action = finishing_action("approved", holder: false)
    approval = Event.find_by!(task_id: task.id, type: "action.approved")

    assert T.apply(action_request("grant_action_lease", id: task.id)).completed?
    assert_equal "approved", action.reload.state
    assert_empty RuleCheck.where(task_id: task.id)
    assert_equal approval.id, Event.find_by!(task_id: task.id, type: "action.approved").id
    event = Event.find_by!(task_id: task.id, type: "action.lease_granted")
    assert_equal [ "app", action.id, @builder.id ], [ event.actor_kind, event.subject_id, event.payload.fetch("lease_seat_id") ]
  end
end
