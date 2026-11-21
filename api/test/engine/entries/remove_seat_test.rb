require "test_helper"
require_relative "accounts_support"
require_relative "call_spy"
require_relative "pending_ends_support"

# remove_seat (PRD L148, L823; milestone 2 plan IN-17, IN-40, SC-10): writes
# seat.removed, sets removed_at, ends the token at once, clears wanted
# running and, for a seat the app runs, queues stop_seat. A Working task the
# seat holds is released to Ready with seat_removed, with no builder, as
# every return to Ready clears it (the PRD's replay list); a review it holds
# with a live lease is released, so another reviewer can claim it. The
# seat-bound holds of the task it loses close after task.released, which
# then leaves the wait_ready cause to hold.closed (milestone 3 plan §2.1
# rule 7, HE-35).
#
# What the seat held is taken away from a waiting command (milestone 4 plan
# §2.1 rule 11): a pending submit, a pending pass or a provisional claim of
# the removed seat is cancelled with invalid_state, through
# PendingTransitions.cancel, after seat.removed and before the task or the
# review is released. A job the seat holds as a checker or a planner is left
# to its run timeout: no job event is written for it.
class RemoveSeatTest < ActiveSupport::TestCase
  include AccountsSupport
  include CallSpy
  include PendingEndsSupport

  setup { use_scenario }

  def remove(seat, **options) = owner_command("remove_seat", { "id" => seat.id }, **options)

  test "a seat that connects on its own is removed and its token answers no more" do
    seat = own_seat
    key = new_key
    written = events_written { assert_completed(remove(seat, key: key)) }

    assert_equal [ "seat.removed" ], written.map(&:type)
    assert_equal [ "seat", seat.id, "owner", @scenario.owner.id, key ],
      [ written.first.subject_kind, written.first.subject_id, written.first.actor_kind, written.first.actor_id,
        written.first.command_id ]
    seat.reload
    assert_equal written.first.at, seat.removed_at
    assert_nil seat.token_hash
    assert_not signs_in?(seat)
    assert_equal 0, HelperRequest.where(seat_id: seat.id).count
  end

  test "a seat the app runs is no longer wanted running and is stopped" do
    seat = running_seat
    outcome = assert_completed(remove(seat))

    seat.reload
    assert_equal [ false, nil ], [ seat.wanted_running, seat.token_hash ]
    stop = HelperRequest.find_by!(seat_id: seat.id, kind: "stop_seat")
    assert_equal [ "queued", seat.credential_id ], [ stop.state, stop.credential_id ]
    assert_equal stop.id, outcome.result.fetch("helper_request_id")
  end

  test "a Working task the seat holds is released to Ready with seat_removed, after seat.removed" do
    seat = own_seat
    task = @scenario.task(state: "working", builder: seat)
    written = events_written { assert_completed(remove(seat)) }

    assert_equal [ "seat.removed", "task.released" ], written.map(&:type)
    released = written.last
    assert_equal({ "reason" => "seat_removed", "wait_cause" => nil }, released.payload)
    assert_equal [ task.id, nil, nil, written.first.id ], [ released.task_id, released.subject_kind, released.subject_id, released.cause_id ]
    task.reload
    assert_equal [ "ready", nil, nil, nil ], [ task.state, task.holder_seat_id, task.lease_due_at, task.lease_time_left_while_paused ]
    assert_nil task.builder_seat_id, "a task back in Ready has no builder"
    assert_empty Leverage::Replay.diff(@scenario.workspace_id), "the replay of the log agrees with the tables"
  end

  test "a task whose lease is already past its due time is left to the lease timer" do
    seat = own_seat
    @scenario.make_due(@scenario.task(state: "working", builder: seat))
    written = events_written { assert_completed(remove(seat)) }

    assert_includes written.map(&:type), "seat.removed"
    assert_not_includes written.map(&:type), "task.released", "an ended lease is the timer's (task.lease_expired), not a release"
  end

  test "a review the seat holds is released by Remove, so another reviewer can claim it" do
    reviewer = own_seat(role: "reviewer")
    review = @scenario.review(@scenario.task(state: "in_review"), reviewer: reviewer)
    written = events_written { assert_completed(remove(reviewer)) }

    assert_equal [ "seat.removed", "review.released" ], written.map(&:type)
    released = written.last
    assert_equal [ "review", review.id, "owner" ], [ released.subject_kind, released.subject_id, released.actor_kind ]
    review.reload
    assert_equal [ nil, nil, nil ], [ review.reviewer_seat_id, review.lease_due_at, review.lease_time_left_while_paused ]
    other = own_seat(role: "reviewer")
    assert_equal review.id, Leverage::Eligibility.next_review(other)&.id
    assert_empty Leverage::Replay.diff(@scenario.workspace_id), "the replay of the log agrees with the tables"
  end

  test "a review whose lease is already past its due time is left to the review lease timer" do
    reviewer = own_seat(role: "reviewer")
    @scenario.make_due(@scenario.review(@scenario.task(state: "in_review"), reviewer: reviewer))
    written = events_written { assert_completed(remove(reviewer)) }

    assert_equal [ "seat.removed" ], written.map(&:type)
  end

  test "a removed seat is not found" do
    seat = own_seat
    assert_completed(remove(seat))

    assert_raises(T::NotFound) { remove(seat) }
  end

  test "an unknown seat is not found" do
    assert_raises(T::NotFound) { owner_command("remove_seat", { "id" => SecureRandom.uuid }) }
  end

  test "the seat-bound holds of the released task are closed after task.released, with the wait_ready cause" do
    own = @scenario.credential
    seat = @scenario.seat(credential: own, run_state: "stopped", wanted_running: true)
    task = @scenario.task(state: "working", builder: seat)
    @scenario.limit_credential(own, reset_at: @scenario.database_now + 3600, seat: seat, task: task)
    @scenario.hold(task, reason: "credential_limit", credential: own, item: false)

    calls = spy_on(Leverage::Holds, :close_seat_bound) do
      @written = events_written { assert_completed(remove(seat)) }
    end

    released = @written.find { |event| event.type == "task.released" }
    assert_equal({ "reason" => "seat_removed", "wait_cause" => nil }, released.payload)
    assert_equal [ [ task.id, released.id, nil ] ],
      calls.map { |call| [ call.arguments.last.id, call.keywords[:cause].id, call.keywords[:wait_cause] ] },
      "no other builder exists, so the cause is not credential_limit (HE-35)"
  end

  test "a builder's pending submit is cancelled with invalid_state after seat.removed and before task.released" do
    seat = own_seat
    task = @scenario.task(state: "working", builder: seat)
    pending = @scenario.pending_transition(task, command: "submit", requester: seat)
    written = nil
    calls = recording_cancels { written = events_written { assert_completed(remove(seat)) } }

    assert_equal [ Cancelled.new(pending.id, "invalid_state", %w[seat.removed]) ], calls
    assert_equal %w[seat.removed task.released], written.map(&:type)
  end

  test "a reviewer's pending pass is cancelled with invalid_state after seat.removed and before review.released" do
    seat = own_seat(role: "reviewer")
    task = @scenario.task(state: "in_review")
    review = @scenario.review(task, reviewer: seat)
    pending = @scenario.pending_transition(task, command: "pass_review", requester: seat)
    written = nil
    calls = recording_cancels { written = events_written { assert_completed(remove(seat)) } }

    assert_equal [ Cancelled.new(pending.id, "invalid_state", %w[seat.removed]) ], calls
    assert_equal %w[seat.removed review.released], written.map(&:type)
    assert_nil review.reload.reviewer_seat_id
  end

  test "a provisional claimant's claim is cancelled with invalid_state; the cancel is all the task gets" do
    seat = own_seat
    task = @scenario.task(state: "ready")
    task.update!(holder_seat_id: seat.id)
    pending = @scenario.pending_transition(task, command: "claim", requester: seat)
    written = nil
    calls = recording_cancels { written = events_written { assert_completed(remove(seat)) } }

    assert_equal [ Cancelled.new(pending.id, "invalid_state", %w[seat.removed]) ], calls
    assert_equal %w[seat.removed], written.map(&:type), "a provisional claim has no lease and no task.claimed to undo"
  end

  test "a seat with nothing pending cancels nothing, and a Working task whose lease has ended is left to its timer" do
    seat = own_seat
    @scenario.make_due(@scenario.task(state: "working", builder: seat))
    reviewer = own_seat(role: "reviewer")
    @scenario.review(@scenario.task(state: "in_review"), reviewer: reviewer)

    assert_empty recording_cancels { assert_completed(remove(seat)); assert_completed(remove(reviewer)) }
  end

  test "an orchestrator's claimed job is left to its run timeout: no job event, the job still claimed" do
    orchestrator = @scenario.orchestrator
    task = @scenario.task(state: "ready")
    @scenario.rule_check(task, rule: @scenario.rule(hook: "task.before_claim"), started: true, checker: orchestrator)
    job = Job.where(claimed_by_seat_id: orchestrator.id).sole
    written = events_written { assert_completed(remove(orchestrator)) }

    assert_equal %w[seat.removed], written.map(&:type)
    assert_equal [ "claimed", orchestrator.id ], Job.find(job.id).attributes.values_at("state", "claimed_by_seat_id")
  end
end
