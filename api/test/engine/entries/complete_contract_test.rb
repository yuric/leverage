require "test_helper"

# Complete contract (PRD Lifecycle L80, L175; milestone 2 plan SC-3): from
# Backlog to Ready at task.before_ready, writing task.contract_changed and
# task.ready. The last criterion is the independent review (PRD Terms).
class CompleteContractTest < ActiveSupport::TestCase
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
    @scenario = Scenario.new
    @owner = @scenario.owner
    @task = @scenario.task(state: "backlog", work_reference: nil)
  end

  def apply(params)
    key = "key-#{SecureRandom.hex(6)}"
    @key = key
    T.apply(T::Request.new(command: "complete_contract", workspace_id: @scenario.workspace_id, caller_kind: "owner",
      caller_id: @owner.id, key: key, request_hash: Digest::SHA256.hexdigest(params.to_json), params: params))
  end

  def written = Event.where(workspace_id: @scenario.workspace_id, command_id: @key).order(:seq).to_a

  def body(task = @task, **fields)
    { "id" => task.id, "title" => "Update the pricing page", "goal" => "The page shows this year's prices.",
      "details" => "Use the figures in the price list.",
      "criteria" => [ { "text" => "The copy names this year's prices.", "kind" => "build" },
                      { "text" => "The layout matches the rest of the site.", "kind" => "build" },
                      { "text" => "An independent reviewer agrees.", "kind" => "review" } ],
      "actions" => [], "minimum_strength_rank" => nil, "budget_cap" => nil,
      "work_reference" => "~/work/pricing-page" }.merge(fields.stringify_keys)
  end

  test "completes the contract: criteria, task.contract_changed, task.ready, and the task is Ready" do
    gating = Recording.new
    Leverage::Gating.implementation = gating
    outcome = apply(body(minimum_strength_rank: 2, budget_cap: 5.5))

    assert outcome.completed?
    @task.reload
    assert_equal [ "ready", 1, "The page shows this year's prices.", "Use the figures in the price list.",
                   "~/work/pricing-page", 2 ],
      @task.attributes.values_at("state", "contract_version", "goal", "details", "work_reference", "minimum_strength_rank")
    assert_equal BigDecimal("5.5"), @task.budget_cap
    criteria = Criterion.where(task_id: @task.id).order(:position)
    assert_equal [ [ 1, "build", "open" ], [ 2, "build", "open" ], [ 3, "review", "open" ] ],
      criteria.map { |row| [ row.position, row.kind, row.state ] }

    changed, ready = written
    assert_equal %w[task.contract_changed task.ready], written.map(&:type)
    assert_equal({ "contract_version" => 1, "minimum_strength_rank" => 2, "added_criterion_ids" => criteria.map(&:id),
                   "reset_criterion_ids" => [],
                   "removed_criterion_ids" => [], "added_action_ids" => [], "removed_action_ids" => [] }, changed.payload)
    assert_equal({ "wait_cause" => nil }, ready.payload)
    assert_equal [ "owner", @owner.id, 0 ], [ ready.actor_kind, ready.actor_id, ready.round ]
    assert_equal [ "task.before_ready" ], gating.hooks
  end

  test "an outward action is 422 invalid (SC-3)" do
    assert_raises(T::Invalid) { apply(body(actions: [ { "kind" => "publish", "description" => "Made-up." } ])) }
    assert_equal "backlog", @task.reload.state
  end

  test "the last criterion, and only the last, is the independent review" do
    build = { "text" => "Made-up build criterion.", "kind" => "build" }
    review = { "text" => "An independent reviewer agrees.", "kind" => "review" }
    [ [ build ], [ review, build ], [ build, review, review ], [] ].each do |criteria|
      assert_raises(T::Invalid, criteria.inspect) { apply(body(criteria: criteria)) }
    end
    assert apply(body(criteria: [ review ])).completed?
  end

  test "a work reference with sign-in details is 422 invalid" do
    assert_raises(T::Invalid) { apply(body(work_reference: "https://example.test/repo?token=made-up-value")) }
  end

  test "from any state but Backlog it is invalid_state and writes nothing" do
    ready = @scenario.task(state: "ready")
    outcome = apply(body(ready))

    assert_equal "invalid_state", outcome.refusal.code
    assert_empty written
    assert_equal 1, ready.reload.contract_version
  end

  test "an unknown task, or another workspace's, is not found" do
    assert_raises(T::NotFound) { apply(body.merge("id" => SecureRandom.uuid)) }
    assert_raises(T::NotFound) { apply(body(Scenario.new.task(state: "backlog"))) }
  end

  test "an open contract_incomplete hold closes first (L175)" do
    hold = ActiveRecord::Base.transaction(requires_new: true) do
      Leverage::Holds.open(@scenario.context, task: @task, reason: "contract_incomplete")
    end
    assert apply(body).completed?

    assert_equal %w[hold.closed task.contract_changed task.ready], written.map(&:type)
    assert hold.reload.closed_at
  end
end
