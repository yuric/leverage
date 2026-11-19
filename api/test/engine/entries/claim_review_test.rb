require "test_helper"

# Claim review (PRD Lifecycle L89, L506; milestone 2 plan EN-7, EN-23;
# DB-20): a reviewer seat claims the oldest open review at review.assign;
# review.started records its credential and model; the result carries the
# review, the lease, the reviewer's briefing and the work reference.
class ClaimReviewTest < ActiveSupport::TestCase
  include OpenapiAssertions

  T = Leverage::Transitions

  # Records the hooks gating is asked at.
  class Recording < Leverage::Gating::NoRules
    attr_reader :hooks

    def initialize
      super
      @hooks = []
    end

    def evaluate(request)
      @hooks << request.hook
      super
    end
  end

  setup do
    @scenario = Scenario.new(lease_length_seconds: 600)
    @credential = @scenario.credential(provider: "codex")
    @reviewer = @scenario.seat(role: "reviewer", credential: @credential, model: "")
    @task = @scenario.task(state: "in_review", work_reference: "~/work/pricing-page")
    @review = Review.find_by!(task_id: @task.id)
  end

  def apply(seat)
    key = "key-#{SecureRandom.hex(6)}"
    @key = key
    T.apply(T::Request.new(command: "claim_review", workspace_id: @scenario.workspace_id, caller_kind: "seat",
      caller_id: seat.id, key: key, request_hash: "claim_review", params: {}))
  end

  def written = Event.where(workspace_id: @scenario.workspace_id, command_id: @key).order(:seq).to_a

  test "claims the review: the reviewer holds it under a lease" do
    gating = Recording.new
    Leverage::Gating.implementation = gating
    outcome = apply(@reviewer)

    assert outcome.completed?
    @review.reload
    assert_equal [ @reviewer.id, @credential.id ], @review.attributes.values_at("reviewer_seat_id", "credential_id")
    event = written.sole
    assert_equal [ "review.started", "seat", @reviewer.id, "review", @review.id, 0 ],
      [ event.type, event.actor_kind, event.actor_id, event.subject_kind, event.subject_id, event.round ]
    assert_equal({ "credential_id" => @credential.id, "model" => nil }, event.payload)
    assert_in_delta event.at + 600, @review.lease_due_at, 0.001
    assert_equal "in_review", @task.reload.state
    assert_equal [ "review.assign" ], gating.hooks
  end

  test "the result is the contract's ClaimReviewResult, with the reviewer's briefing" do
    result = apply(@reviewer).result

    assert_matches_component("ClaimReviewResult", result)
    assert_equal @review.id, result.dig("review", "id")
    assert_equal @reviewer.id, result.dig("lease", "seat_id")
    assert_equal Leverage::Briefing.hash_for(@task, seat: @reviewer, review: @review), result.dig("briefing", "hash")
    assert_equal Leverage::RoleFiles.text("reviewer"), result.dig("briefing", "role_file")
    assert_equal [ "~/work/pricing-page", @credential.id, nil ], result.values_at("work_reference", "credential_id", "model")
  end

  test "no open review is not_eligible; so is a builder seat" do
    apply(@reviewer)
    assert_equal "not_eligible", apply(@scenario.seat(role: "reviewer")).refusal.code
    @scenario.task(state: "in_review")
    assert_equal "not_eligible", apply(@scenario.seat(role: "builder")).refusal.code
  end

  test "a reviewer holding a review is not_eligible for another" do
    @scenario.task(state: "in_review")
    apply(@reviewer)
    assert_equal "not_eligible", apply(@reviewer).refusal.code
  end

  test "the reviewer of a review with a verdict may claim the next one (DB-20)" do
    apply(@reviewer)
    @review.update!(verdict: "failed", lease_due_at: nil)
    @task.update!(round: 1)
    nxt = Review.create!(workspace_id: @task.workspace_id, task_id: @task.id, round: 1)

    assert apply(@reviewer).completed?
    assert_equal @reviewer.id, nxt.reload.reviewer_seat_id
    assert_equal @reviewer.id, @review.reload.reviewer_seat_id
  end

  # A review whose lease is past its due time has no reviewer (L120,
  # EN-14), whether or not the sweep has run: another reviewer claims it,
  # after its review.lease_expired at the due time.
  test "a review whose lease is past its due time is claimed by another reviewer, after the lease ends" do
    first = @scenario.seat(role: "reviewer")
    @scenario.review(@task, reviewer: first)
    due = @scenario.make_due(@review.reload).lease_due_at
    before = @scenario.workspace.reload.last_seq

    assert apply(@reviewer).completed?
    assert_equal @reviewer.id, @review.reload.reviewer_seat_id
    events = Event.where(workspace_id: @scenario.workspace_id).where("seq > ?", before).order(:seq).to_a
    assert_equal %w[review.lease_expired review.started], events.map(&:type)
    assert_in_delta due.to_f, events.first.effective_at.to_f, 0.000_001
    assert_nil events.first.command_id
  end
end
