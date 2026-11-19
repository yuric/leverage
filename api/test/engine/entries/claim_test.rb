require "test_helper"

# Claim (PRD Lifecycle L83, L492, L544-L545; milestone 2 plan EN-7, EN-8,
# EN-23): a builder seat claims the next eligible Ready task at
# task.before_claim; task.claimed records the seat, its credential and its
# model, and the result carries the task, the lease, the briefing, the work
# reference, the credential and the model.
class ClaimTest < ActiveSupport::TestCase
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
    @credential = @scenario.credential
    @builder = @scenario.seat(role: "builder", credential: @credential, model: "claude-model-1")
  end

  def apply(seat)
    key = "key-#{SecureRandom.hex(6)}"
    @key = key
    T.apply(T::Request.new(command: "claim", workspace_id: @scenario.workspace_id, caller_kind: "seat",
      caller_id: seat.id, key: key, request_hash: "claim", params: {}))
  end

  def written = Event.where(workspace_id: @scenario.workspace_id, command_id: @key).order(:seq).to_a

  test "claims the Ready task: Working, the seat holds it and builds it, and the lease runs" do
    task = @scenario.task(state: "ready", work_reference: "~/work/pricing-page")
    gating = Recording.new
    Leverage::Gating.implementation = gating
    outcome = apply(@builder)

    assert outcome.completed?
    task.reload
    assert_equal [ "working", @builder.id, @builder.id, @credential.id ],
      task.attributes.values_at("state", "holder_seat_id", "builder_seat_id", "credential_id")
    event = written.sole
    assert_equal [ "task.claimed", "seat", @builder.id, task.id, 0 ],
      [ event.type, event.actor_kind, event.actor_id, event.task_id, event.round ]
    assert_equal({ "seat_id" => @builder.id, "credential_id" => @credential.id, "model" => "claude-model-1" }, event.payload)
    assert_in_delta event.at + 600, task.lease_due_at, 0.001
    assert_equal [ "task.before_claim" ], gating.hooks
  end

  test "the result is the contract's ClaimTaskResult" do
    task = @scenario.task(state: "ready", work_reference: "~/work/pricing-page")
    result = apply(@builder).result

    assert_matches_component("ClaimTaskResult", result)
    assert_equal task.id, result.dig("task", "id")
    assert_equal "working", result.dig("task", "state")
    assert_equal @builder.id, result.dig("lease", "seat_id")
    assert_equal task.reload.lease_due_at.utc.iso8601(6), result.dig("lease", "lease_due_at")
    assert_equal Leverage::Briefing.hash_for(task, seat: @builder), result.dig("briefing", "hash")
    assert_equal "~/work/pricing-page", result["work_reference"]
    assert_equal [ @credential.id, "claude-model-1" ], result.values_at("credential_id", "model")
  end

  test "a seat whose model is empty records model null; a seat that connects on its own records no credential" do
    @scenario.task(state: "ready")
    own = @scenario.seat(role: "builder", model: "")
    result = apply(own).result

    assert_equal [ nil, nil ], result.values_at("credential_id", "model")
    assert_equal({ "seat_id" => own.id, "credential_id" => nil, "model" => nil }, written.sole.payload)
  end

  test "nothing to claim is not_eligible" do
    @scenario.task(state: "backlog")
    outcome = apply(@builder)
    assert_equal "not_eligible", outcome.refusal.code
    assert_empty written
  end

  test "a reviewer seat, or a builder holding a task, is not_eligible" do
    @scenario.task(state: "ready")
    assert_equal "not_eligible", apply(@scenario.seat(role: "reviewer")).refusal.code

    busy = @scenario.seat(role: "builder")
    @scenario.task(state: "working", builder: busy)
    assert_equal "not_eligible", apply(busy).refusal.code
  end

  test "two claims never get the same task" do
    first = @scenario.task(state: "ready")
    second = @scenario.task(state: "ready")
    other = @scenario.seat(role: "builder")

    ids = [ apply(@builder), apply(other) ].map { |outcome| outcome.result.dig("task", "id") }
    assert_equal [ first.id, second.id ].sort, ids.sort
  end
end
