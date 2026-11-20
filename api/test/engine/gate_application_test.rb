require "test_helper"
require_relative "gate_support"

# Transitions::Gate (milestone 4 plan §2.1 rules 1 to 8, ADR 0011): what it
# asks at a hook, what it writes of the plan, and the outcome it makes of
# it. Against StandIn worlds and evaluations a test writes itself; the
# rules engine (WP3) is not here.
class GateApplicationTest < ActiveSupport::TestCase
  include GateSupport

  # Answers one Evaluation a test gives it, built from the request.
  class Planned < Leverage::Gating::NoRules
    attr_reader :requests

    def initialize(&plan)
      super()
      @plan = plan
      @requests = []
    end

    def evaluate(request)
      @requests << request
      @plan.call(request)
    end
  end

  setup do
    @scenario = Scenario.new
    @owner = @scenario.owner
    @builder = @scenario.seat(role: "builder", credential: @scenario.credential)
  end

  def check_of(rule, request, result:, reason: nil)
    version = @scenario.current_version(rule)
    Leverage::Gating::PlannedCheck.new(rule_id: rule.id, rule_version_id: version.id, hook: request.hook, round: request.round,
      subject_kind: request.subject_kind, subject_id: request.subject_id,
      input_hash: Leverage::Gating.input_hash(hook: request.hook, inputs: request.inputs), checker: version.checker,
      result: result, effect: nil, reason: reason)
  end

  def evaluation(outcome: :completed, checks: [], jobs: [], failures: [], warnings: [], holds: [], deferred: [])
    Leverage::Gating::Evaluation.new(outcome: outcome, frozen_rule_version_ids: [], checks: checks, jobs: jobs,
      failures: failures, warnings: warnings, effects: [], holds_to_open: holds, deferred_rule_ids: deferred)
  end

  test "it asks with the hook's hashed inputs from HookInputs, the task, its round and the subject: the seat at before an agent starts it" do
    gating = Planned.new { evaluation }
    Leverage::Gating.implementation = gating
    task = @scenario.task(state: "ready")
    assert command("claim", @builder).completed?

    request = gating.requests.sole
    assert_equal [ "task.before_claim", task.id, 0, "seat", @builder.id, "seat", @builder.id, @key ],
      [ request.hook, request.task_id, request.round, request.subject_kind, request.subject_id, request.requester_kind,
        request.requester_id, request.command_key ]
    assert_equal Leverage::HookInputs.for(hook: "task.before_claim", task: task, params: {}, seat: @builder), request.inputs
  end

  test "with nothing planned the gate writes nothing: RuleChecks.write is not called" do
    task = @scenario.task(state: "backlog")
    calls = spy_on(Leverage::RuleChecks, :write) { assert command("complete_contract", @owner, contract_params(task)).completed? }

    assert_empty calls
  end

  test "at ready to start it asks with the requested contract, not the stored one" do
    gating = Planned.new { evaluation }
    Leverage::Gating.implementation = gating
    task = @scenario.task(state: "backlog")
    params = contract_params(task, details: "Requested details.")
    command("complete_contract", @owner, params)

    assert_equal Leverage::HookInputs.for(hook: "task.before_ready", task: task, params: params), gating.requests.sole.inputs
    assert_equal "Requested details.", gating.requests.sole.inputs["details"]
  end

  test "a blocking app failure beside a planned model check takes effect at once: the model check, its job and the wait are not written" do
    app = app_rule("task.before_submit")
    model = custom_rule("task.before_submit")
    Leverage::Gating.implementation = Planned.new do |request|
      checks = [ check_of(app, request, result: "failed", reason: "Made-up reason."), check_of(model, request, result: nil) ]
      evaluation(outcome: :pending, checks: checks, jobs: [ job_for(1) ],
        failures: [ Leverage::Gating::Failure.new(rule_id: app.id, rule_check_ref: 0, reason: "Made-up reason.", route: "builder") ])
    end
    task = ready_to_submit(@builder)
    outcome = with_jobs { command("submit", @builder, submit_params(task)) }

    assert_equal [ "blocked_by_rule", app.id, "Made-up reason." ], outcome.refusal.to_h.values_at("code", "rule_id", "reason")
    assert_equal [ "check.finished" ], types
    assert_equal [ app.id ], mine(RuleCheck).pluck(:rule_id)
    assert_nil Leverage::PendingTransitions.of(task)
    assert_empty @job_calls
  end

  test "beside a blocking failure, a hold planned for a model check that is not written does not open" do
    app = app_rule("task.before_submit")
    model = custom_rule("task.before_submit")
    Leverage::Gating.implementation = Planned.new do |request|
      evaluation(outcome: :pending, checks: [ check_of(app, request, result: "failed"), check_of(model, request, result: nil) ],
        failures: [ Leverage::Gating::Failure.new(rule_id: app.id, rule_check_ref: 0, reason: nil, route: "builder") ],
        holds: [ Leverage::Gating::PlannedHold.new(reason: "rerun_limit", rule_id: model.id, rule_check_id: 1) ])
    end
    task = ready_to_submit(@builder)

    assert command("submit", @builder, submit_params(task)).refused?
    assert_equal [ "check.finished" ], types
    assert_not mine(Hold).exists?
  end

  test "a warn failure is recorded on its row and lets the command through (L337)" do
    app_rule("task.before_submit", on_fail: "warn")
    Leverage::Gating.implementation = Planned.new do |request|
      rule = mine(Rule).sole
      evaluation(checks: [ check_of(rule, request, result: "failed") ],
        warnings: [ Leverage::Gating::Failure.new(rule_id: rule.id, rule_check_ref: 0, reason: nil, route: "builder") ])
    end
    task = ready_to_submit(@builder)

    assert command("submit", @builder, submit_params(task)).completed?
    assert_equal %w[check.finished task.submitted], types
    assert_equal "failed", mine(RuleCheck).sole.result
  end

  test "a run past the re-run limit waits: its row is written with no job and no event, and rerun_limit opens with its item (trace 17, RD-45)" do
    rule = custom_rule("task.before_submit")
    Leverage::Gating.implementation = Planned.new do |request|
      evaluation(outcome: :pending, checks: [ check_of(rule, request, result: nil) ],
        holds: [ Leverage::Gating::PlannedHold.new(reason: "rerun_limit", rule_id: rule.id, rule_check_id: 0) ])
    end
    task = ready_to_submit(@builder)
    outcome = with_jobs { command("submit", @builder, submit_params(task)) }

    assert_equal :pending, outcome.outcome
    assert_equal %w[hold.opened inbox.opened], types
    opened, item = written
    check = mine(RuleCheck).sole
    assert_equal [ "app", nil, @key, nil ], [ opened.actor_kind, opened.actor_id, opened.command_id, opened.cause_id ]
    assert_equal [ "app", opened.id ], [ item.actor_kind, item.cause_id ]
    hold = mine(Hold).sole
    assert_equal [ "rerun_limit", rule.id, check.id ], hold.values_at(:reason, :rule_id, :rule_check_id)
    assert_equal({ "rule_id" => rule.id, "rule_check_id" => check.id }, mine(InboxItem).sole.facts)
    assert_equal Leverage::PendingTransitions.of(task).id, check.pending_transition_id
    assert_empty @job_calls
    assert_not RuleCheckAttempt.exists?(rule_check_id: check.id)
  end

  test "a failed claim gate that reaches its third seat opens claim_gate_failed, caused by the check's check.finished" do
    rule = app_rule("task.before_claim")
    Leverage::Gating.implementation = Planned.new do |request|
      evaluation(checks: [ check_of(rule, request, result: "failed") ],
        failures: [ Leverage::Gating::Failure.new(rule_id: rule.id, rule_check_ref: 0, reason: nil, route: "builder") ],
        holds: [ Leverage::Gating::PlannedHold.new(reason: "claim_gate_failed", rule_id: rule.id, rule_check_id: 0) ])
    end
    task = @scenario.task(state: "ready")
    outcome = command("claim", @builder)

    assert_equal "blocked_by_rule", outcome.refusal.code
    assert_equal %w[check.finished hold.opened inbox.opened], types
    finished, opened = written
    assert_equal [ "app", finished.id ], [ opened.actor_kind, opened.cause_id ]
    assert_equal [ task.id, "claim_gate_failed", mine(RuleCheck).sole.id ], mine(Hold).sole.values_at(:task_id, :reason, :rule_check_id)
    assert_equal [ "ready", nil ], task.reload.values_at(:state, :holder_seat_id)
  end

  test "a check_error hold opens its item only while the orchestrator is online (SM-39)" do
    rule = custom_rule("task.before_submit")
    task = ready_to_submit(@builder)
    check = @scenario.rule_check(task, rule: rule, result: "error")
    planned = Leverage::Gating::PlannedHold.new(reason: "check_error", rule_id: rule.id, rule_check_id: check.id)
    ActiveRecord::Base.transaction(requires_new: true) { T::Gate.open_hold(@scenario.context, task, planned, check_id: check.id) }
    assert_not mine(InboxItem).exists?, "no orchestrator has polled: offline"

    @scenario.orchestrator(last_polled_at: @scenario.database_now)
    second = @scenario.rule_check(@scenario.task(state: "working", builder: @scenario.seat(role: "builder")), rule: rule,
      result: "error")
    ActiveRecord::Base.transaction(requires_new: true) do
      T::Gate.open_hold(@scenario.context, Task.find(second.task_id), planned.with(rule_check_id: second.id), check_id: second.id)
    end
    assert_equal "check_could_not_run", mine(InboxItem).sole.kind
  end

  test "an evaluation that waits with no task to wait on, or defers policies, is an error, not a silent pass" do
    Leverage::Gating.implementation = Planned.new { evaluation(outcome: :pending) }
    entry = Class.new(T::Entry) do
      def hook = "task.before_claim"
      def perform(_ctx) = @result = {}
    end
    T::Table.with_entries("claim" => entry) do
      assert_raises(T::Gate::Unsupported) { command("claim", @builder) }
    end
    Leverage::Gating.implementation = Planned.new { evaluation(deferred: [ SecureRandom.uuid ]) }
    @scenario.task(state: "ready")
    assert_raises(T::Gate::Unsupported) { command("claim", @builder) }
  end

  test "Complete contract closes an open contract_incomplete hold before the gate, also when it then waits (trace 16, L176)" do
    with_jobs do
      gating(custom_rule("task.before_ready", route: "owner"))
      task = @scenario.task(state: "backlog")
      @scenario.hold(task, reason: "contract_incomplete")

      assert_equal :pending, command("complete_contract", @owner, contract_params(task)).outcome
      assert_equal %w[hold.closed check.queued job.queued], types
      assert_not Leverage::Holds.held?(task)
    end
  end

  test "the owner's Complete contract withdraws the task's open draft job; a planner's does not (RD-37)" do
    with_jobs do
      task = @scenario.task(state: "backlog")
      draft = @scenario.job(kind: "contract_draft", task: task)
      assert command("complete_contract", @owner, contract_params(task)).completed?
      assert_equal [ [ :withdraw, draft.id ] ], @job_calls.map { |name, call| [ name, call[:job].id ] }

      other = @scenario.task(state: "backlog")
      @scenario.job(kind: "contract_draft", task: other)
      @job_calls.clear
      planner = @scenario.planner
      answer = ActiveRecord::Base.transaction(requires_new: true) do
        T.run_as(@scenario.context, "complete_contract", requester: planner, key: "k-planner",
          params: contract_params(other))
      end
      assert_equal :completed, answer
      assert_empty @job_calls
    end
  end

  private

  def job_for(index) = Leverage::Gating::PlannedJob.new(kind: "rule_check", rule_check_ref: index, seat_role: "orchestrator")
end
