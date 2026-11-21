require "test_helper"
require_relative "accounts_support"

class MarkActionDoneTest < ActiveSupport::TestCase
  include AccountsSupport

  setup { use_scenario }

  test "an unconfirmed hold does not allow the owner to mark a requested action done" do
    task = scenario.finishing_task(holder: false, actions: [
      { state: "requested", description: "First made-up action." },
      { state: "approved", description: "Second made-up action." }
    ])
    requested, approved = Action.where(task_id: task.id).order(:position).to_a
    hold = scenario.hold(task, reason: "action_unconfirmed", facts: { action_ids: [ approved.id ],
      approved_by_kind: "owner", approved_by_id: scenario.owner.id, builder_announced_start: false })

    assert_empty events_written {
      assert_refused "invalid_state", owner_command("mark_action_done", { "id" => requested.id })
    }
    assert_nil hold.reload.closed_at
  end
end
