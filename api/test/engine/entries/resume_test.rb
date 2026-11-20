require "test_helper"
require_relative "owner_controls_support"

# Resume (PRD Lifecycle L104, Holds L176; milestone 3 plan HE-24, HS-3):
# closes the task's owner_hold and nothing else. Without one it is
# invalid_state (the row's guard not_held_owner_hold). When no pausing hold
# is left the lease clocks run again, and when no hold is left on a task a
# seat holds, its next GET /v1/next answers resume. Finishing is not served.
class ResumeTest < ActiveSupport::TestCase
  include OwnerControlsSupport

  setup do
    use_scenario
    @builder = scenario.seat(role: "builder", credential: scenario.credential)
  end

  test "closes the owner_hold: hold.closed by the owner, the lease runs again, resume pending" do
    task = working_task(@builder)
    owner_run("hold", "id" => task.id)
    hold = open_holds(task).sole
    outcome, events = owner_run("resume", "id" => task.id)

    assert_completed(outcome)
    assert_nil outcome.result
    event = events.sole
    assert_equal [ "hold.closed", "owner", scenario.owner.id, hold.id, nil ],
      [ event.type, event.actor_kind, event.actor_id, event.subject_id, event.cause_id ]
    assert_equal({ "reason" => "owner_hold", "rule_id" => nil, "credential_id" => nil, "lease_seat_id" => nil,
                   "wait_cause" => nil }, event.payload)
    assert hold.reload.closed_at
    task.reload
    assert task.lease_due_at
    assert_nil task.lease_time_left_while_paused
    assert task.resume_pending_since
  end

  test "closes only the owner_hold: another hold stays open" do
    task = working_task(@builder)
    open_hold(task, "rounds_exceeded", facts: { round: 0 })
    owner_run("hold", "id" => task.id)
    outcome, events = owner_run("resume", "id" => task.id)

    assert_completed(outcome)
    assert_equal %w[hold.closed], events.map(&:type)
    assert_equal %w[rounds_exceeded], open_holds(task).map(&:reason)
    assert_nil task.reload.resume_pending_since
  end

  test "without an owner_hold it is invalid_state, also when another hold is open" do
    task = working_task(@builder)
    outcome, events = owner_run("resume", "id" => task.id)
    assert_refused("invalid_state", outcome)
    assert_empty events

    open_hold(task, "rounds_exceeded", facts: { round: 0 })
    outcome, events = owner_run("resume", "id" => task.id)
    assert_refused("invalid_state", outcome)
    assert_empty events
    assert_equal %w[rounds_exceeded], open_holds(task).map(&:reason)
  end

  test "resumes from every state that has a row, and the state does not change" do
    %w[imaginarium backlog ready working in_review].each do |state|
      task = scenario.task(state: state)
      owner_run("hold", "id" => task.id)
      outcome, events = owner_run("resume", "id" => task.id)

      assert_completed(outcome)
      assert_equal %w[hold.closed], events.map(&:type), state
      assert_equal state, task.reload.state
    end
  end

  test "Finishing has a row that is not served in this milestone: invalid_state, even with an owner_hold (HS-3)" do
    task = scenario.finishing_task(builder: @builder)
    ActiveRecord::Base.transaction(requires_new: true) do
      Leverage::Holds.open(scenario.context, task: task, reason: "owner_hold", actor_kind: "owner",
        actor_id: scenario.owner.id)
    end
    outcome, events = owner_run("resume", "id" => task.id)

    assert_refused("invalid_state", outcome)
    assert_empty events
    assert_equal %w[owner_hold], open_holds(task).map(&:reason)
  end

  test "Done and Cancelled are invalid_state" do
    %w[done cancelled].each do |state|
      outcome, events = owner_run("resume", "id" => scenario.task(state: state).id)

      assert_refused("invalid_state", outcome)
      assert_empty events, state
    end
  end

  test "an unknown task is not found" do
    assert_raises(T::NotFound) { owner_run("resume", "id" => SecureRandom.uuid) }
  end
end
