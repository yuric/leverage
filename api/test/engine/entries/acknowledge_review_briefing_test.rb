require "test_helper"

# Acknowledge review briefing (PRD Lifecycle L85, L475; DB-11): the reviewer
# holding the review acknowledges the reviewer's briefing hash under its
# review lease; task.briefing_acknowledged names the review.
class AcknowledgeReviewBriefingTest < ActiveSupport::TestCase
  T = Leverage::Transitions
  B = Leverage::Briefing

  setup do
    @scenario = Scenario.new
    @reviewer = @scenario.seat(role: "reviewer")
    @task = @scenario.task(state: "in_review")
    @review = @scenario.review(@task, reviewer: @reviewer)
  end

  def apply(seat, params)
    key = "key-#{SecureRandom.hex(6)}"
    @key = key
    T.apply(T::Request.new(command: "acknowledge_review_briefing", workspace_id: @scenario.workspace_id,
      caller_kind: "seat", caller_id: seat.id, key: key, request_hash: Digest::SHA256.hexdigest(params.to_json),
      params: params))
  end

  def written = Event.where(workspace_id: @scenario.workspace_id, command_id: @key).order(:seq).to_a

  def current(seat = @reviewer)
    { "id" => @review.id, "briefing_hash" => B.hash_for(@task, seat: seat, review: @review) }
  end

  test "acknowledges the reviewer's hash under the review lease" do
    assert apply(@reviewer, current).completed?

    event = written.sole
    assert_equal [ "task.briefing_acknowledged", "seat", @reviewer.id, "review", @review.id, @task.id ],
      [ event.type, event.actor_kind, event.actor_id, event.subject_kind, event.subject_id, event.task_id ]
    started = Event.find_by!(task_id: @task.id, type: "review.started")
    row = BriefingAcknowledgement.find_by!(review_id: @review.id)
    assert_equal [ @reviewer.id, @task.id, started.id ], row.attributes.values_at("seat_id", "task_id", "lease_event_id")
    assert_equal :current, B.acknowledgement(@task, seat: @reviewer, review: @review)
  end

  test "the builder's hash is not the reviewer's: briefing_changed" do
    outcome = apply(@reviewer, "id" => @review.id, "briefing_hash" => B.hash_for(@task, seat: @scenario.seat(role: "builder")))
    assert_equal "briefing_changed", outcome.refusal.code
    assert_empty written
  end

  test "a seat that does not hold the review is not_holder" do
    other = @scenario.seat(role: "reviewer")
    assert_equal "not_holder", apply(other, current(other)).refusal.code
    builder = @scenario.seat(role: "builder")
    assert_equal "not_holder", apply(builder, current(builder)).refusal.code
  end

  test "an unknown review is not found" do
    assert_raises(T::NotFound) { apply(@reviewer, "id" => SecureRandom.uuid, "briefing_hash" => "made-up") }
  end
end
