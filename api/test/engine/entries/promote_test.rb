require "test_helper"
require_relative "owner_controls_support"

# Promote (PRD Lifecycle L78; milestone 3 plan HE-24): the owner moves an
# idea from the Imaginarium to the Backlog with task.promoted. Every other
# state has no row: invalid_state.
class PromoteTest < ActiveSupport::TestCase
  include OwnerControlsSupport

  setup { use_scenario }

  test "an idea moves to the Backlog with task.promoted by the owner" do
    task = scenario.task(state: "imaginarium")
    outcome, events = owner_run("promote", "id" => task.id)

    assert_completed(outcome)
    assert_nil outcome.result
    assert_equal "backlog", task.reload.state
    event = events.sole
    assert_equal [ "task.promoted", "owner", scenario.owner.id, task.id, {} ],
      [ event.type, event.actor_kind, event.actor_id, event.task_id, event.payload ]
  end

  test "the idea step closes and the contract step opens" do
    task = scenario.task(state: "imaginarium")
    owner_run("promote", "id" => task.id)

    assert_equal "wait_contract", TaskStep.find_by!(task_id: task.id, closed_at: nil).kind
  end

  test "a hold does not stop it: promote is not a seat's work" do
    task = scenario.task(state: "imaginarium")
    open_hold(task, "owner_hold")
    outcome, = owner_run("promote", "id" => task.id)

    assert_completed(outcome)
    assert_equal "backlog", task.reload.state
  end

  test "from any other state it is invalid_state and writes nothing" do
    %w[backlog ready working in_review done cancelled].each do |state|
      task = scenario.task(state: state)
      outcome, events = owner_run("promote", "id" => task.id)

      assert_refused("invalid_state", outcome)
      assert_empty events, state
      assert_equal state, task.reload.state
    end
  end

  test "an unknown task is not found" do
    assert_raises(T::NotFound) { owner_run("promote", "id" => SecureRandom.uuid) }
  end
end
