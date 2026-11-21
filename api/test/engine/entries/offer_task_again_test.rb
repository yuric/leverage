require "test_helper"
require_relative "accounts_support"

class OfferTaskAgainTest < ActiveSupport::TestCase
  include AccountsSupport

  setup { use_scenario }

  test "a removed builder cannot be offered the task again even after it held the action lease" do
    builder = scenario.seat
    task = scenario.finishing_task(builder: builder, actions: [ { state: "approved", description: "Made-up action." } ])
    action = Action.find_by!(task_id: task.id)
    hold = scenario.hold(task, reason: "action_unconfirmed", facts: { action_ids: [ action.id ],
      approved_by_kind: "owner", approved_by_id: scenario.owner.id, builder_announced_start: false })
    scenario.remove(builder)

    assert_empty events_written {
      assert_refused "invalid_state", owner_command("offer_task_again", { "id" => task.id })
    }
    assert_nil hold.reload.closed_at
  end
end
