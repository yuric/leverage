require "test_helper"
require_relative "owner_controls_support"

# Hold (PRD Lifecycle L104, Holds L168, L176; milestone 3 plan HE-24):
# the owner holds a task with owner_hold in any state but Done and
# Cancelled. hold.opened is the owner's; owner_hold has no Needs you item
# and pauses the lease clocks.
class HoldTest < ActiveSupport::TestCase
  include OwnerControlsSupport

  setup do
    use_scenario
    @builder = scenario.seat(role: "builder", credential: scenario.credential)
  end

  test "holds a Working task with owner_hold: hold.opened by the owner, no item, the lease paused" do
    task = working_task(@builder)
    outcome, events = owner_run("hold", "id" => task.id)

    assert_completed(outcome)
    assert_nil outcome.result
    event = events.sole
    hold = ::Hold.find(event.subject_id)
    assert_equal [ "hold.opened", "owner", scenario.owner.id, nil, task.id ],
      [ event.type, event.actor_kind, event.actor_id, event.cause_id, event.task_id ]
    assert_equal({ "reason" => "owner_hold", "rule_id" => nil, "credential_id" => nil, "rule_check_id" => nil }, event.payload)
    assert_equal [ "owner_hold", "owner", scenario.owner.id ], hold.attributes.values_at("reason", "opened_by_kind", "opened_by_id")
    assert_empty InboxItem.where(hold_id: hold.id)
    task.reload
    assert_equal "working", task.state
    assert_nil task.lease_due_at
    assert task.lease_time_left_while_paused
  end

  test "holds a task In review and pauses the review lease too" do
    task = scenario.task(state: "in_review", builder: @builder)
    review = scenario.review(task)
    outcome, = owner_run("hold", "id" => task.id)

    assert_completed(outcome)
    assert_nil review.reload.lease_due_at
    assert review.lease_time_left_while_paused
  end

  test "the state does not change, from every state that has a row" do
    %w[ideas backlog ready working in_review].each do |state|
      task = scenario.task(state: state)
      outcome, events = owner_run("hold", "id" => task.id)

      assert_completed(outcome)
      assert_equal %w[hold.opened], events.map(&:type), state
      assert_equal state, task.reload.state
    end
  end

  test "the builder's work calls are blocked while it is held" do
    task = working_task(@builder)
    refute Leverage::Eligibility.on_hold?(task)
    owner_run("hold", "id" => task.id)

    assert Leverage::Eligibility.on_hold?(task.reload)
  end

  test "a task already held by the owner is invalid_state: one owner_hold at a time" do
    task = scenario.task(state: "ready")
    owner_run("hold", "id" => task.id)
    outcome, events = owner_run("hold", "id" => task.id)

    assert_refused("invalid_state", outcome)
    assert_empty events
    assert_equal 1, ::Hold.where(task_id: task.id, reason: "owner_hold").count
  end

  test "another hold does not stop the owner's" do
    task = working_task(@builder)
    open_hold(task, "rounds_exceeded", facts: { round: 0 })
    outcome, = owner_run("hold", "id" => task.id)

    assert_completed(outcome)
    assert_equal %w[rounds_exceeded owner_hold], open_holds(task).map(&:reason)
  end

  test "the owner can hold a Finishing task that has no holder" do
    task = scenario.finishing_task(builder: @builder, holder: false, actions: [ { kind: "send", state: "requested" } ])
    outcome, events = owner_run("hold", "id" => task.id)

    assert_completed(outcome)
    assert_equal %w[hold.opened], events.map(&:type)
    assert_equal %w[owner_hold], open_holds(task).map(&:reason)
    assert_equal [ "finishing", nil, nil ], task.reload.attributes.values_at("state", "holder_seat_id", "lease_due_at")
  end

  test "Done and Cancelled are invalid_state" do
    %w[done cancelled].each do |state|
      outcome, events = owner_run("hold", "id" => scenario.task(state: state).id)

      assert_refused("invalid_state", outcome)
      assert_empty events, state
    end
  end

  test "an unknown task is not found" do
    assert_raises(T::NotFound) { owner_run("hold", "id" => SecureRandom.uuid) }
  end
end
