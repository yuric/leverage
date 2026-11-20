require "test_helper"
require_relative "owner_controls_support"

# Pause a seat (PRD L169, L258; milestone 3 plan HE-26): seat.paused by the
# owner. The seat claims nothing more; a task it holds is held with
# seat_paused (hold.opened by the app, caused by seat.paused), whose lease
# keeps running (L121), and no run is stopped. A paused reviewer keeps its
# review: no task hold (M1 G40). Pausing a paused seat is invalid_state.
class PauseSeatTest < ActiveSupport::TestCase
  include OwnerControlsSupport

  setup do
    use_scenario
    @builder = running_seat
  end

  test "a seat with no task: seat.paused by the owner, and it claims nothing more" do
    outcome, events = owner_run("pause_seat", "id" => @builder.id)

    assert_completed(outcome)
    assert_nil outcome.result
    event = events.sole
    assert_equal [ "seat.paused", "owner", scenario.owner.id, "seat", @builder.id, nil, {} ],
      [ event.type, event.actor_kind, event.actor_id, event.subject_kind, event.subject_id, event.task_id, event.payload ]
    assert @builder.reload.paused
    scenario.task(state: "ready")
    refute Leverage::Eligibility.may_claim?(@builder, :task)
  end

  test "the task the seat holds is held with seat_paused, caused by seat.paused; the lease keeps running" do
    task = working_task(@builder)
    due = task.lease_due_at
    outcome, events = owner_run("pause_seat", "id" => @builder.id)

    assert_completed(outcome)
    paused, opened = events
    assert_equal %w[seat.paused hold.opened], events.map(&:type)
    assert_equal [ "app", nil, paused.id, task.id ], [ opened.actor_kind, opened.actor_id, opened.cause_id, opened.task_id ]
    assert_equal({ "reason" => "seat_paused", "rule_id" => nil, "credential_id" => nil }, opened.payload)
    assert_empty InboxItem.where(hold_id: opened.subject_id)
    task.reload
    assert_equal [ "working", @builder.id, due ], task.attributes.values_at("state", "holder_seat_id", "lease_due_at")
    assert_nil task.lease_time_left_while_paused
  end

  test "the run is not stopped: nothing is queued and the run state stays" do
    working_task(@builder)
    owner_run("pause_seat", "id" => @builder.id)

    assert_empty HelperRequest.where(workspace_id: scenario.workspace_id, seat_id: @builder.id)
    assert_equal [ "running", true ], @builder.reload.attributes.values_at("run_state", "wanted_running")
  end

  test "a paused reviewer keeps its review, with no task hold" do
    reviewer = scenario.seat(role: "reviewer", credential: scenario.credential(provider: "codex"))
    task = scenario.task(state: "in_review")
    review = scenario.review(task, reviewer: reviewer)
    due = review.lease_due_at
    outcome, events = owner_run("pause_seat", "id" => reviewer.id)

    assert_completed(outcome)
    assert_equal %w[seat.paused], events.map(&:type)
    assert_equal [ reviewer.id, due ], review.reload.attributes.values_at("reviewer_seat_id", "lease_due_at")
    assert_empty open_holds(task)
  end

  test "a task whose lease has passed its due time is its timer's, and is not held" do
    task = working_task(@builder)
    scenario.make_due(task)
    outcome, events = owner_run("pause_seat", "id" => @builder.id)

    assert_completed(outcome)
    refute_includes events.map(&:type), "hold.opened"
  end

  test "pausing a paused seat is invalid_state and writes nothing" do
    owner_run("pause_seat", "id" => @builder.id)
    outcome, events = owner_run("pause_seat", "id" => @builder.id)

    assert_refused("invalid_state", outcome)
    assert_empty events
  end

  test "a removed or unknown seat is not found" do
    scenario.remove(@builder)
    assert_raises(T::NotFound) { owner_run("pause_seat", "id" => @builder.id) }
    assert_raises(T::NotFound) { owner_run("pause_seat", "id" => SecureRandom.uuid) }
  end
end
