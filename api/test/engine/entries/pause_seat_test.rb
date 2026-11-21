require "test_helper"
require_relative "owner_controls_support"
require_relative "pending_ends_support"

# Pause a seat (PRD L169, L258; milestone 3 plan HE-26): seat.paused by the
# owner. The seat claims nothing more; a task it holds is held with
# seat_paused (hold.opened by the app, caused by seat.paused), whose lease
# keeps running (L121), and no run is stopped. A paused reviewer keeps its
# review: no task hold (M1 G40). Pausing a paused seat is invalid_state.
#
# A provisional claim of the paused seat is cancelled with invalid_state,
# through PendingTransitions.cancel, and no hold opens for it (milestone 4
# plan §2.1 rule 11, RD-13); a pending submit of a builder that holds a
# task is not cancelled, and seat_paused opens as before (L378).
class PauseSeatTest < ActiveSupport::TestCase
  include OwnerControlsSupport
  include PendingEndsSupport

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
    assert_equal({ "reason" => "seat_paused", "rule_id" => nil, "credential_id" => nil, "rule_check_id" => nil }, opened.payload)
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

  test "a provisional claim is cancelled with invalid_state after seat.paused, and no hold opens for it" do
    task = scenario.task(state: "ready")
    task.update!(holder_seat_id: @builder.id)
    pending = scenario.pending_transition(task, command: "claim", requester: @builder)
    events = nil
    calls = recording_cancels { _, events = owner_run("pause_seat", "id" => @builder.id) }

    assert_equal [ Cancelled.new(pending.id, "invalid_state", %w[seat.paused]) ], calls
    assert_equal %w[seat.paused], events.map(&:type)
    assert_empty open_holds(task)
    assert @builder.reload.paused
  end

  test "a paused builder's pending submit keeps its transition and gets seat_paused" do
    task = working_task(@builder)
    pending = scenario.pending_transition(task, command: "submit", requester: @builder)
    events = nil
    calls = recording_cancels { _, events = owner_run("pause_seat", "id" => @builder.id) }

    assert_empty calls
    assert_equal %w[seat.paused hold.opened], events.map(&:type)
    assert_equal "pending", pending.reload.state
    assert_equal [ "seat_paused" ], open_holds(task).map(&:reason)
  end

  test "a paused reviewer keeps its review and its pending pass" do
    reviewer = running_seat(role: "reviewer")
    task = scenario.task(state: "in_review")
    review = scenario.review(task, reviewer: reviewer)
    pending = scenario.pending_transition(task, command: "pass_review", requester: reviewer)
    events = nil
    calls = recording_cancels { _, events = owner_run("pause_seat", "id" => reviewer.id) }

    assert_empty calls
    assert_equal %w[seat.paused], events.map(&:type)
    assert_equal [ reviewer.id, "pending" ], [ review.reload.reviewer_seat_id, pending.reload.state ]
  end

  test "a provisional claim of another seat is left alone" do
    other = running_seat
    task = scenario.task(state: "ready")
    task.update!(holder_seat_id: other.id)
    scenario.pending_transition(task, command: "claim", requester: other)
    calls = recording_cancels { owner_run("pause_seat", "id" => @builder.id) }

    assert_empty calls
  end
end
