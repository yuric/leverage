require "test_helper"
require_relative "call_spy"
require_relative "../gate_support"

# Complete contract (PRD Lifecycle L80, L175; milestone 2 plan SC-3): from
# Backlog to Ready at task.before_ready, writing task.contract_changed and
# task.ready. The last criterion is the independent review (PRD Terms).
class CompleteContractTest < ActiveSupport::TestCase
  include CallSpy

  T = Leverage::Transitions

  # Records the hooks gating is asked at.
  class Recording < Leverage::Rules::Engine
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

  def apply(params, command: "complete_contract")
    key = "key-#{SecureRandom.hex(6)}"
    @key = key
    T.apply(T::Request.new(command: command, workspace_id: @scenario.workspace_id, caller_kind: "owner",
      caller_id: @owner.id, key: key, request_hash: Digest::SHA256.hexdigest(params.to_json), params: params))
  end

  def written = Event.where(workspace_id: @scenario.workspace_id, command_id: @key).order(:seq).to_a

  def body(task = @task, **fields)
    { "id" => task.id, "title" => "Update the pricing page",
      "details" => "The page shows this year's prices.\n\nUse the figures in the price list.",
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
    assert_equal [ "ready", 1, "Update the pricing page", "The page shows this year's prices.\n\nUse the figures in the price list.",
                   "~/work/pricing-page", 2 ],
      @task.attributes.values_at("state", "contract_version", "title", "details", "work_reference", "minimum_strength_rank")
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

  test "completing the contract records its ordered outward actions" do
    outcome = apply(body(actions: [ { "kind" => "send", "description" => "Send the price list." },
                                   { "kind" => "publish", "description" => "Publish the prices." } ]))

    assert outcome.completed?
    actions = Action.where(task_id: @task.id).order(:position)
    assert_equal [ [ 1, "send", "contracted" ], [ 2, "publish", "contracted" ] ], actions.pluck(:position, :kind, :state)
    assert_equal actions.map(&:id), written.first.payload.fetch("added_action_ids")
    assert_empty written.first.payload.fetch("removed_action_ids")
  end

  test "completing the contract preserves an unchanged outward action from Add task" do
    definitions = [ { "kind" => "publish", "description" => "Publish the prices." } ]
    added = apply({ "title" => @task.title, "details" => @task.details, "actions" => definitions }, command: "add_task")
    assert added.completed?
    task = Task.find(added.result.fetch("task_id"))
    original_action = Action.where(task_id: task.id).sole

    assert apply(body(task, actions: definitions)).completed?

    assert_equal original_action.id, Action.where(task_id: task.id).sole.id
    assert_empty written.first.payload.fetch("added_action_ids")
    assert_empty written.first.payload.fetch("removed_action_ids")
  end

  test "completing the contract applies the saved cap through Costs (AE-12)" do
    outcome = nil
    calls = spy_on(Leverage::Costs, :cap_changed) do
      outcome = apply(body(budget_cap: 7.5))
    end

    assert outcome.completed?
    assert_equal [ [ @task.id, BigDecimal("7.5") ] ], calls.map { |call| [ call.arguments.last.id, call.arguments.last.budget_cap ] }
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

  # HE-35: the wait_ready step task.ready opens names credential_limit when
  # a builder would take the task but for its accounts, none of them is
  # available, and none is signed out.
  test "task.ready names credential_limit when every builder that could take the task waits for a limit (HE-35)" do
    claude = @scenario.credential(provider: "claude")
    @scenario.seat(role: "builder", credential: claude)
    @scenario.limit_credential(claude, reset_at: @scenario.database_now + 3600)

    assert apply(body).completed?
    assert_equal({ "wait_cause" => "credential_limit" }, written.last.payload)
    assert_equal "credential_limit", TaskStep.find_by!(task_id: @task.id, kind: "wait_ready").cause_kind
  end

  test "task.ready names no cause when a builder can take the task, or one of their logins is signed out" do
    claude = @scenario.credential(provider: "claude")
    codex = @scenario.credential(provider: "codex")
    @scenario.seat(role: "builder", credential: claude)
    @scenario.limit_credential(claude, reset_at: @scenario.database_now + 3600)
    @scenario.sign_out_credential(codex)

    assert apply(body).completed?
    assert_equal({ "wait_cause" => nil }, written.last.payload)
  end

  # Edit contract (milestone 3) returns a task to the Backlog with its
  # criteria; Complete contract then keeps each criterion whose position,
  # kind and text are unchanged, with its state, and diffs the rest by
  # position and kind as Edit contract does (HE-25 (i); trace 15).
  def returned_to_backlog
    @task = @scenario.task(state: "working", criteria: %w[build build review], work_reference: nil)
    copy, layout, = Criterion.where(task_id: @task.id).order(:position).to_a
    copy.update!(text: "The copy names this year's prices.", state: "passed", passed_at: @scenario.database_now)
    layout.update!(text: "The layout matches the rest of the site.")
    Criterion.find_by!(task_id: @task.id, kind: "review").update!(text: "An independent reviewer agrees.")
    @task.update!(state: "backlog", holder_seat_id: nil, builder_seat_id: nil, lease_due_at: nil)
    @scenario.append("task.returned", task: @task, actor_kind: "owner", actor_id: @owner.id)
    Criterion.where(task_id: @task.id).order(:position).to_a
  end

  test "an unchanged contract keeps every criterion, with its state, and only the version goes up" do
    kept = returned_to_backlog
    version = @task.contract_version

    assert apply(body).completed?
    changed = written.first
    assert_equal({ "contract_version" => version + 1, "minimum_strength_rank" => nil, "added_criterion_ids" => [],
                   "reset_criterion_ids" => [], "removed_criterion_ids" => [], "added_action_ids" => [],
                   "removed_action_ids" => [] }, changed.payload)
    assert_equal kept.map(&:id), Criterion.where(task_id: @task.id, removed_at: nil).order(:position).pluck(:id)
    assert_equal "passed", kept.first.reload.state
  end

  test "a changed text resets its criterion, a new position is added, a gone one removed, a changed kind both" do
    copy, layout, review = returned_to_backlog
    criteria = [ { "text" => "The copy names next year's prices.", "kind" => "build" },
                 { "text" => "The layout matches the rest of the site.", "kind" => "review" } ]

    assert apply(body(criteria: criteria)).completed?
    payload = written.first.payload
    added = Criterion.where(task_id: @task.id, removed_at: nil, position: 2).sole
    assert_equal [ [ added.id ], [ copy.id ], [ layout.id, review.id ].sort ],
      [ payload["added_criterion_ids"], payload["reset_criterion_ids"], payload["removed_criterion_ids"].sort ]
    copy.reload
    assert_equal [ "open", "The copy names next year's prices.", nil ], [ copy.state, copy.text, copy.passed_at ]
    assert layout.reload.removed_at
    assert review.reload.removed_at
    assert_equal [ copy.id, added.id ], Criterion.where(task_id: @task.id, removed_at: nil).order(:position).pluck(:id)
  end
end

# Complete contract at its gate (milestone 4 plan §2.1 rules 6 and 7, RD-10,
# RE-6): a failed gate commits the contract change alone and opens
# contract_incomplete; a model check makes it wait with its request kept.
class CompleteContractGatedTest < ActiveSupport::TestCase
  include GateSupport

  setup do
    @scenario = Scenario.new
    @owner = @scenario.owner
  end

  test "a failed gate commits the contract change only: Backlog, the next version, contract_incomplete naming the rule and its check" do
    rule = app_rule("task.before_ready")
    gating([ rule, { app_result: "failed" } ])
    task = @scenario.task(state: "backlog")
    outcome = command("complete_contract", @owner, contract_params(task))

    assert outcome.completed?
    assert_equal %w[check.finished task.contract_changed hold.opened], types
    finished, changed, opened = written
    assert_equal [ "backlog", 1 ], task.reload.values_at(:state, :contract_version)
    assert_equal 2, Criterion.where(task_id: task.id).count
    assert_equal [ "owner", @owner.id, finished.id ], [ opened.actor_kind, opened.actor_id, opened.cause_id ]
    assert_equal({ "reason" => "contract_incomplete", "rule_id" => rule.id, "credential_id" => nil, "rule_check_id" => nil },
      opened.payload)
    assert_equal mine(RuleCheck).sole.id, mine(Hold).sole.rule_check_id
    assert_nil changed.cause_id
  end

  test "a model check makes it wait: the task stays in Backlog and the request is kept for the move" do
    with_jobs do
      gating(custom_rule("task.before_ready", route: "owner"))
      task = @scenario.task(state: "backlog")
      params = contract_params(task)

      assert_equal :pending, command("complete_contract", @owner, params).outcome
      assert_equal [ "backlog", 0 ], task.reload.values_at(:state, :contract_version)
      assert_equal params, Leverage::PendingTransitions.of(task).params
      assert_equal 0, Criterion.where(task_id: task.id).count
    end
  end
end
