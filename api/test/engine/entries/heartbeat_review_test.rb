require "test_helper"

# Review heartbeat (PRD L120, L507): the reviewer holding the review renews
# its lease; no event. After the review lease ended it is lease_expired.
class HeartbeatReviewTest < ActiveSupport::TestCase
  T = Leverage::Transitions

  setup do
    @scenario = Scenario.new(lease_length_seconds: 600)
    @reviewer = @scenario.seat(role: "reviewer")
    @task = @scenario.task(state: "in_review")
    @review = @scenario.review(@task, reviewer: @reviewer)
  end

  def apply(seat)
    key = "key-#{SecureRandom.hex(6)}"
    @key = key
    T.apply(T::Request.new(command: "heartbeat_review", workspace_id: @scenario.workspace_id, caller_kind: "seat",
      caller_id: seat.id, key: key, request_hash: "heartbeat_review", params: { "id" => @review.id }))
  end

  def written = Event.where(workspace_id: @scenario.workspace_id, command_id: @key).order(:seq).to_a

  test "renews the review lease from now and writes no event" do
    before = @scenario.database_now
    outcome = apply(@reviewer)

    assert outcome.completed?
    due = @review.reload.lease_due_at
    assert_operator due, :>=, before + 600
    assert_equal({ "lease_due_at" => due.utc.iso8601(6) }, outcome.result)
    assert_empty written
  end

  test "after the review lease expired it is lease_expired" do
    @review.update!(reviewer_seat_id: nil, lease_due_at: nil)
    @scenario.append("review.lease_expired", task: @task, subject: @review)
    assert_equal "lease_expired", apply(@reviewer).refusal.code
  end

  test "a seat that does not hold the review is not_holder" do
    assert_equal "not_holder", apply(@scenario.seat(role: "reviewer")).refusal.code
  end

  test "an unknown review is not found" do
    assert_raises(T::NotFound) do
      T.apply(T::Request.new(command: "heartbeat_review", workspace_id: @scenario.workspace_id, caller_kind: "seat",
        caller_id: @reviewer.id, key: "key-unknown", request_hash: "x", params: { "id" => SecureRandom.uuid }))
    end
  end
end
