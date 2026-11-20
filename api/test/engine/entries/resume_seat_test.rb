require "test_helper"
require_relative "owner_controls_support"

# Resume a seat (PRD L169, L258; milestone 3 plan HE-26): seat.resumed by
# the owner, then the seat_paused hold on the task it holds closes
# (hold.closed by the owner, caused by seat.resumed), and with no hold
# left the seat's next GET /v1/next answers resume. Resuming a seat that
# is not paused is invalid_state.
class ResumeSeatTest < ActiveSupport::TestCase
  include OwnerControlsSupport

  setup do
    use_scenario
    @builder = running_seat
  end

  test "a seat with no task: seat.resumed by the owner, and it may claim again" do
    owner_run("pause_seat", "id" => @builder.id)
    outcome, events = owner_run("resume_seat", "id" => @builder.id)

    assert_completed(outcome)
    assert_nil outcome.result
    event = events.sole
    assert_equal [ "seat.resumed", "owner", scenario.owner.id, "seat", @builder.id, nil, {} ],
      [ event.type, event.actor_kind, event.actor_id, event.subject_kind, event.subject_id, event.task_id, event.payload ]
    refute @builder.reload.paused
    scenario.task(state: "ready")
    assert Leverage::Eligibility.may_claim?(@builder, :task)
  end

  test "closes the seat_paused hold on the task it holds, caused by seat.resumed; resume pending" do
    task = working_task(@builder)
    owner_run("pause_seat", "id" => @builder.id)
    hold = open_holds(task).sole
    outcome, events = owner_run("resume_seat", "id" => @builder.id)

    assert_completed(outcome)
    resumed, closed = events
    assert_equal %w[seat.resumed hold.closed], events.map(&:type)
    assert_equal [ "owner", scenario.owner.id, resumed.id, hold.id, task.id ],
      [ closed.actor_kind, closed.actor_id, closed.cause_id, closed.subject_id, closed.task_id ]
    assert_equal({ "reason" => "seat_paused", "rule_id" => nil, "credential_id" => nil, "lease_seat_id" => nil,
                   "wait_cause" => nil }, closed.payload)
    assert_empty open_holds(task)
    assert task.reload.resume_pending_since
  end

  test "another hold on the task stays open" do
    task = working_task(@builder)
    owner_run("pause_seat", "id" => @builder.id)
    owner_run("hold", "id" => task.id)
    outcome, events = owner_run("resume_seat", "id" => @builder.id)

    assert_completed(outcome)
    assert_equal %w[seat.resumed hold.closed], events.map(&:type)
    assert_equal %w[owner_hold], open_holds(task).map(&:reason)
    assert_nil task.reload.resume_pending_since
  end

  test "resuming a seat that is not paused is invalid_state and writes nothing" do
    outcome, events = owner_run("resume_seat", "id" => @builder.id)

    assert_refused("invalid_state", outcome)
    assert_empty events
  end

  test "a removed or unknown seat is not found" do
    scenario.remove(@builder)
    assert_raises(T::NotFound) { owner_run("resume_seat", "id" => @builder.id) }
    assert_raises(T::NotFound) { owner_run("resume_seat", "id" => SecureRandom.uuid) }
  end
end
