require "test_helper"

# Leverage::Leases.ended_by_expiry? (milestone 2 plan EN-15): a seat whose
# latest lease on the task or review ended with task.lease_expired or
# review.lease_expired, and which has no newer lease on it, is refused
# lease_expired; after anything else, not_holder. It is read from the
# events, which Scenario appends here.
class LeaseEndTest < ActiveSupport::TestCase
  L = Leverage::Leases

  setup do
    @scenario = Scenario.new
    @builder = @scenario.seat(role: "builder")
    @other = @scenario.seat(role: "builder")
  end

  def expire(task)
    task.update!(state: "ready", holder_seat_id: nil, lease_due_at: nil)
    @scenario.append("task.lease_expired", task: task, payload: { wait_cause: nil })
  end

  def claim(task, seat)
    task.update!(state: "working", holder_seat_id: seat.id, builder_seat_id: seat.id)
    @scenario.append("task.claimed", task: task, actor_kind: "seat", actor_id: seat.id,
      payload: { seat_id: seat.id, credential_id: nil, model: nil })
  end

  test "a builder whose lease expired is told lease_expired" do
    task = @scenario.task(state: "working", builder: @builder)
    expire(task)

    assert L.ended_by_expiry?(task, @builder)
    assert L.ended_by_expiry?(task, @builder.id), "a seat id works as well as a seat"
  end

  test "a seat that never held the task, or still holds it, is not" do
    task = @scenario.task(state: "working", builder: @builder)

    refute L.ended_by_expiry?(task, @builder)
    refute L.ended_by_expiry?(task, @other)
  end

  test "an expiry belongs to the seat that held the lease then" do
    task = @scenario.task(state: "working", builder: @builder)
    expire(task)
    claim(task, @other)
    expire(task)

    assert L.ended_by_expiry?(task, @other)
    assert L.ended_by_expiry?(task, @builder), "the builder's latest lease still ended by expiry"
  end

  test "a newer lease after the expiry clears it" do
    task = @scenario.task(state: "working", builder: @builder)
    expire(task)
    claim(task, @builder)

    refute L.ended_by_expiry?(task, @builder)
  end

  test "a lease that ended any other way is not an expiry" do
    task = @scenario.task(state: "working", builder: @builder)
    task.update!(state: "ready", holder_seat_id: nil, lease_due_at: nil)
    @scenario.append("task.released", task: task, actor_kind: "seat", actor_id: @builder.id,
      payload: { reason: "unable_to_continue", wait_cause: nil })

    refute L.ended_by_expiry?(task, @builder)
  end

  test "a fresh lease granted by a failed review counts as a newer lease" do
    task = @scenario.task(state: "working", builder: @builder)
    expire(task)
    review = Review.create!(workspace_id: @scenario.workspace_id, task_id: task.id, round: 0)
    @scenario.append("review.failed", task: task, subject: review, actor_kind: "seat", actor_id: @other.id,
      payload: { failed_criterion_ids: [], failed_rule_check_id: nil, lease_seat_id: @builder.id, wait_cause: nil })

    refute L.ended_by_expiry?(task, @builder)
  end

  test "a reviewer whose review lease expired is told lease_expired, for that review only" do
    reviewer = @scenario.seat(role: "reviewer")
    task = @scenario.task(state: "in_review", builder: @builder)
    review = @scenario.review(task, reviewer: reviewer)
    refute L.ended_by_expiry?(review, reviewer)

    review.update!(reviewer_seat_id: nil, lease_due_at: nil)
    @scenario.append("review.lease_expired", task: task, subject: review)

    assert L.ended_by_expiry?(review, reviewer)
    refute L.ended_by_expiry?(review, @builder)
    refute L.ended_by_expiry?(task, reviewer), "a review's expiry is not the task's"
  end
end
