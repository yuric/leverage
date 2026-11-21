require "test_helper"
require_relative "accounts_support"
require_relative "pending_ends_support"

# report_run_stopped (PRD L121, L823, L914; milestone 2 plan IN-17, IN-40,
# IF-21): a run stopped. The seat's run state becomes stopped and its token
# ends; a review the seat holds is released, so another reviewer can claim
# it; a builder's task keeps its lease until the lease ends. No event of its
# own. The seat keeps why its run stopped and its run is on no credential
# (milestone 3 plan HD-3, HD-10); a report about an earlier run, on another
# credential than the seat's run is on now, changes nothing.
#
# A pending pass of the review the stopped run's seat held (milestone 4 plan
# §2.1 rule 11) is cancelled with invalid_state, through
# PendingTransitions.cancel, before review.released; a builder's pending
# submit is not touched, as its lease runs on (L121).
class ReportRunStoppedTest < ActiveSupport::TestCase
  include AccountsSupport
  include PendingEndsSupport

  setup { use_scenario }

  def report(seat, stop_reason: "stopped", **options)
    helper_command("report_run_stopped", { "id" => seat.id, "credential_id" => seat.credential_id,
      "observed_at" => "2026-11-19T12:00:00Z", "stop_reason" => stop_reason }, **options)
  end

  test "the run is stopped and its token ends, with no event when it holds nothing" do
    seat = running_seat
    written = events_written { assert_completed(report(seat, stop_reason: "error")) }

    assert_empty written
    seat.reload
    assert_equal [ "stopped", nil, true ], [ seat.run_state, seat.token_hash, seat.wanted_running ],
      "a run that dies on its own is not restarted until the helper's next token (IN-30)"
    assert_not signs_in?(seat)
  end

  test "a review the stopped reviewer holds is released as the app, with the helper's key" do
    reviewer = running_seat(role: "reviewer")
    task = @scenario.task(state: "in_review")
    review = @scenario.review(task, reviewer: reviewer)
    written = events_written { assert_completed(report(reviewer, key: "stopped-key")) }

    assert_equal [ "review.released" ], written.map(&:type)
    event = written.first
    assert_equal [ "review", review.id, task.id, "app", @scenario.helper.id, "stopped-key", {} ],
      [ event.subject_kind, event.subject_id, event.task_id, event.actor_kind, event.actor_id, event.command_id, event.payload ]
    review.reload
    assert_equal [ nil, nil, nil ], [ review.reviewer_seat_id, review.lease_due_at, review.verdict ]
    assert_equal "in_review", task.reload.state
  end

  test "another reviewer can claim the released review (L912)" do
    reviewer = running_seat(role: "reviewer")
    task = @scenario.task(state: "in_review")
    review = @scenario.review(task, reviewer: reviewer)
    assert_completed(report(reviewer))
    other = @scenario.seat(role: "reviewer", credential: @scenario.credential(provider: "codex"))

    claim = T.apply(T::Request.new(command: "claim_review", workspace_id: @scenario.workspace_id, caller_kind: "seat",
      caller_id: other.id, key: new_key, request_hash: "e" * 64, params: {}))

    assert_completed(claim)
    assert_equal other.id, review.reload.reviewer_seat_id
  end

  test "a builder's Working task keeps its lease when the run stops (L121)" do
    builder = running_seat(role: "builder")
    task = @scenario.task(state: "working", builder: builder)
    written = events_written { assert_completed(report(builder)) }

    assert_empty written
    task.reload
    assert_equal [ "working", builder.id ], [ task.state, task.holder_seat_id ]
    assert_not_nil task.lease_due_at
  end

  test "a review whose lease is already past its due time is left to the lease timer" do
    reviewer = running_seat(role: "reviewer")
    @scenario.make_due(@scenario.review(@scenario.task(state: "in_review"), reviewer: reviewer))
    written = events_written { assert_completed(report(reviewer)) }

    assert_not_includes written.map(&:type), "review.released"
  end

  test "a removed seat's run stopping releases the review it kept (IN-40)" do
    reviewer = running_seat(role: "reviewer")
    review = @scenario.review(@scenario.task(state: "in_review"), reviewer: reviewer)
    @scenario.remove(reviewer)

    written = events_written { assert_completed(report(reviewer)) }

    assert_equal [ "review.released" ], written.map(&:type)
    assert_nil review.reload.reviewer_seat_id
  end

  test "a seat that connects on its own has no run the app stops" do
    assert_refused("invalid_state", report(own_seat))
  end

  test "an unknown seat is not found" do
    assert_raises(T::NotFound) do
      helper_command("report_run_stopped", { "id" => SecureRandom.uuid, "credential_id" => SecureRandom.uuid,
        "observed_at" => "2026-11-19T12:00:00Z", "stop_reason" => "stopped" })
    end
  end

  test "the run keeps why it stopped and is on no credential any more (HD-3, HD-10)" do
    seat = running_seat

    assert_completed(report(seat, stop_reason: "limit"))

    assert_equal [ "stopped", nil, "limit" ], [ seat.reload.run_state, seat.run_credential_id, seat.run_stop_reason ]
  end

  test "a report about an earlier run of the seat, on another credential, changes nothing" do
    reviewer = running_seat(role: "reviewer")
    review = @scenario.review(@scenario.task(state: "in_review"), reviewer: reviewer)
    other = @scenario.credential(provider: "codex")
    @scenario.run(reviewer, on: other)
    digest = reviewer.reload.token_hash

    written = events_written { assert_completed(report(reviewer, stop_reason: "stopped")) }

    assert_empty written
    reviewer.reload
    assert_equal [ "running", other.id, digest, nil ],
      [ reviewer.run_state, reviewer.run_credential_id, reviewer.token_hash, reviewer.run_stop_reason ]
    assert_equal reviewer.id, review.reload.reviewer_seat_id, "a handed-over review is never released by the old run's stop"
  end

  test "the pending pass of the review the stopped reviewer held is cancelled with invalid_state before review.released" do
    reviewer = running_seat(role: "reviewer")
    task = @scenario.task(state: "in_review")
    review = @scenario.review(task, reviewer: reviewer)
    pending = @scenario.pending_transition(task, command: "pass_review", requester: reviewer)
    written = nil
    calls = recording_cancels { written = events_written { assert_completed(report(reviewer)) } }

    assert_equal [ Cancelled.new(pending.id, "invalid_state", []) ], calls
    assert_equal %w[review.released], written.map(&:type)
    assert_nil review.reload.reviewer_seat_id
  end

  test "a stopped run that holds no review cancels nothing, and a builder's pending submit stays under its lease (L121)" do
    builder = running_seat
    task = @scenario.task(state: "working", builder: builder)
    @scenario.pending_transition(task, command: "submit", requester: builder)
    calls = recording_cancels { assert_completed(report(builder)) }

    assert_empty calls
    assert_equal "pending", PendingTransition.find_by!(task_id: task.id).state
    assert_equal builder.id, task.reload.holder_seat_id
  end

  test "a review whose lease is already past its due time keeps its pending pass for the lease timer" do
    reviewer = running_seat(role: "reviewer")
    task = @scenario.task(state: "in_review")
    @scenario.make_due(@scenario.review(task, reviewer: reviewer))
    @scenario.pending_transition(task, command: "pass_review", requester: reviewer)
    calls = recording_cancels { assert_completed(report(reviewer)) }

    assert_empty calls
  end

  test "a report about an earlier run on another credential cancels nothing" do
    reviewer = running_seat(role: "reviewer")
    task = @scenario.task(state: "in_review")
    @scenario.review(task, reviewer: reviewer)
    @scenario.pending_transition(task, command: "pass_review", requester: reviewer)
    @scenario.run(reviewer, on: @scenario.credential(provider: "codex"))
    calls = recording_cancels { assert_completed(report(reviewer)) }

    assert_empty calls
  end
end
