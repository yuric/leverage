require "test_helper"
require_relative "pending_ends_support"

# The review_lease_expiry timer (PRD L90, L120-L121; timers.json; milestone
# 2 plan WP5): a reviewer's lease that reaches its due time ends. The task
# stays In review and the review is unassigned, so another reviewer can
# claim it; review.lease_expired is written by the app, with no
# command_id, at the due time. Run as its own command (the sweep), it takes
# one review (params review_id) or every due review of the workspace,
# oldest due first, at most params limit of them.
#
# A pending pass under the review whose lease ends (milestone 4 plan §2.1
# rule 11, trace 18 command 45) is cancelled with lease_expired, through
# PendingTransitions.cancel, before review.lease_expired is written.
class ReviewLeaseExpiryTest < ActiveSupport::TestCase
  include PendingEndsSupport

  T = Leverage::Transitions

  setup do
    @scenario = Scenario.new(lease_length_seconds: 600)
    @reviewer = @scenario.seat(role: "reviewer")
  end

  def timer(params = {})
    T.apply(T::Request.new(command: "review_lease_expiry", workspace_id: @scenario.workspace_id, caller_kind: nil,
      caller_id: nil, key: nil, request_hash: nil, params: params))
  end

  def claimed_review(reviewer = @reviewer, due: nil)
    task = @scenario.task(state: "in_review")
    review = @scenario.review(task, reviewer: reviewer)
    due ? @scenario.make_due(review, at: due) : review
  end

  def expiries
    Event.where(workspace_id: @scenario.workspace_id, type: "review.lease_expired").order(:seq).to_a
  end

  test "a due review lease ends: the review unassigned, the task still In review, the event at the due time" do
    review = claimed_review
    due = @scenario.database_now
    @scenario.make_due(review, at: due)

    outcome = timer("review_id" => review.id)

    assert outcome.completed?
    assert_equal({ "expired_review_ids" => [ review.id ] }, outcome.result)
    review.reload
    assert_nil review.reviewer_seat_id
    assert_nil review.lease_due_at
    assert_nil review.verdict
    assert_equal "in_review", Task.find(review.task_id).state

    event = expiries.sole
    assert_in_delta due.to_f, event.effective_at.to_f, 0.000_001
    assert_equal [ "review", review.id, review.task_id ], [ event.subject_kind, event.subject_id, event.task_id ]
    assert_equal [ "app", nil, nil ], [ event.actor_kind, event.actor_id, event.command_id ]
    assert Leverage::Leases.ended_by_expiry?(review, @reviewer)
  end

  test "the seat is free for another review once its lease ended" do
    review = claimed_review(due: @scenario.database_now - 1)
    timer("review_id" => review.id)

    # The unique index on an open review's reviewer would refuse this if
    # the seat still held the first one.
    assert claimed_review(@reviewer)
  end

  test "a review lease that is not due, or is paused, is left as it is" do
    review = claimed_review
    assert_equal [], timer("review_id" => review.id).result.fetch("expired_review_ids")

    review.update_columns(lease_due_at: @scenario.database_now - 60, lease_time_left_while_paused: 30)
    assert_equal [], timer("review_id" => review.id).result.fetch("expired_review_ids")
    assert_equal @reviewer.id, review.reload.reviewer_seat_id
  end

  test "with no review named it ends every due review lease of the workspace, oldest due first, within limit" do
    now = @scenario.database_now
    second = claimed_review(due: now - 10)
    first = claimed_review(@scenario.seat(role: "reviewer"), due: now - 20)
    third = claimed_review(@scenario.seat(role: "reviewer"), due: now - 5)

    assert_equal [ first.id, second.id ], timer("limit" => 2).result.fetch("expired_review_ids")
    assert_equal [ third.id ], timer.result.fetch("expired_review_ids")
  end

  test "a review of a task that is not In review is refused invalid_state" do
    task = @scenario.task(state: "done")
    review = Review.find_by!(task_id: task.id)
    review.update_columns(lease_due_at: @scenario.database_now - 1)

    outcome = timer("review_id" => review.id)

    assert_equal "invalid_state", outcome.refusal&.code
    assert_empty expiries
  end

  test "a review from another workspace is not found" do
    other = Scenario.new
    review = other.review(other.task(state: "in_review"))

    assert_raises(T::NotFound) { timer("review_id" => review.id) }
  end

  test "the lease that ends under a pending pass cancels it with lease_expired before review.lease_expired (rule 11)" do
    review = claimed_review(due: @scenario.database_now - 1)
    task = Task.find(review.task_id)
    pending = @scenario.pending_transition(task, command: "pass_review", requester: @reviewer)
    outcome = nil
    calls = recording_cancels { outcome = timer("review_id" => review.id) }

    assert outcome.completed?
    assert_equal [ Cancelled.new(pending.id, "lease_expired", []) ], calls
    assert_equal [ review.id ], outcome.result.fetch("expired_review_ids")
    assert_equal 1, expiries.size
    assert_nil review.reload.reviewer_seat_id
  end

  test "the sweep's whole-workspace run cancels the pending pass of each review it ends and of no other" do
    other = @scenario.seat(role: "reviewer")
    under_pass = claimed_review(due: @scenario.database_now - 2)
    plain = claimed_review(other, due: @scenario.database_now - 1)
    pending = @scenario.pending_transition(Task.find(under_pass.task_id), command: "pass_review", requester: @reviewer)
    still_live = claimed_review(@scenario.seat(role: "reviewer"))
    @scenario.pending_transition(Task.find(still_live.task_id), command: "pass_review", requester: Seat.find(still_live.reviewer_seat_id))
    calls = recording_cancels { assert timer.completed? }

    assert_equal [ Cancelled.new(pending.id, "lease_expired", []) ], calls,
      "a lease that has not ended keeps its pending pass, and a review with none cancels nothing"
    assert_equal [ under_pass.id, plain.id ].sort, expiries.map(&:subject_id).sort
    assert_not_nil still_live.reload.reviewer_seat_id
  end

  test "a lease that ends with no pending transition cancels nothing" do
    review = claimed_review(due: @scenario.database_now - 1)
    calls = recording_cancels { assert timer("review_id" => review.id).completed? }

    assert_empty calls
  end
end
