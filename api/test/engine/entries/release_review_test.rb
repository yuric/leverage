require "test_helper"

# Release review (PRD Lifecycle L90, L507): the reviewer gives the review
# back; review.released is written, the task stays In review, unassigned,
# and another reviewer can claim it.
class ReleaseReviewTest < ActiveSupport::TestCase
  T = Leverage::Transitions

  setup do
    @scenario = Scenario.new
    @reviewer = @scenario.seat(role: "reviewer")
    @task = @scenario.task(state: "in_review")
    @review = @scenario.review(@task, reviewer: @reviewer)
  end

  def apply(command, seat, params = {})
    key = "key-#{SecureRandom.hex(6)}"
    @key = key
    T.apply(T::Request.new(command: command, workspace_id: @scenario.workspace_id, caller_kind: "seat",
      caller_id: seat.id, key: key, request_hash: Digest::SHA256.hexdigest("#{command}#{params.to_json}"), params: params))
  end

  def written = Event.where(workspace_id: @scenario.workspace_id, command_id: @key).order(:seq).to_a

  test "releases the review: unassigned, no lease, review.released" do
    assert apply("release_review", @reviewer, "id" => @review.id).completed?

    @review.reload
    assert_equal [ nil, nil, nil ], @review.attributes.values_at("reviewer_seat_id", "lease_due_at", "verdict")
    event = written.sole
    assert_equal [ "review.released", "seat", @reviewer.id, "review", @review.id, {} ],
      [ event.type, event.actor_kind, event.actor_id, event.subject_kind, event.subject_id, event.payload ]
    assert_equal "in_review", @task.reload.state
  end

  test "another reviewer can claim it, and so can the same one" do
    apply("release_review", @reviewer, "id" => @review.id)
    assert apply("claim_review", @reviewer).completed?
    assert_equal @reviewer.id, @review.reload.reviewer_seat_id
  end

  test "it is allowed while the task is held" do
    ActiveRecord::Base.transaction(requires_new: true) do
      Leverage::Holds.open(@scenario.context, task: @task, reason: "rounds_exceeded", facts: { round: 0 })
    end
    assert apply("release_review", @reviewer, "id" => @review.id).completed?
  end

  test "a seat that does not hold the review is not_holder" do
    assert_equal "not_holder", apply("release_review", @scenario.seat(role: "reviewer"), "id" => @review.id).refusal.code
  end
end
