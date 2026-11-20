require "test_helper"
require_relative "gate_support"

# Test 3 (PRD L836) for the rows a gate hook guards (milestone 4 plan RT-5,
# §2.1 rules 5 to 7): every state_machine.json row of the task loop whose
# hook is one of the four gate hooks a task can reach (task.before_ready,
# task.before_claim, task.before_submit, task.before_done), each met by a
# rule of four kinds:
#
#   a passing app gate     its check.finished, then the row's events
#   a failing app gate     the hook's failed-gate effect (hooks.json):
#                          hold_contract_incomplete, refuse or failed_review
#   a blocking model gate  pending: check.queued and job.queued, no row
#                          event, the task unmoved, the request stored
#   a warn model gate      the row's events after check.queued and
#                          job.queued (RC-16)
#
# The rows come from StateTableCases; a row a later milestone reaches
# (Finishing, an outward action) is not among them.
class StateTableGatedTest < ActiveSupport::TestCase
  include GateSupport

  GATE_HOOKS = %w[task.before_ready task.before_claim task.before_submit task.before_done].freeze
  KINDS = %i[app_passes app_fails model_blocks model_warns].freeze
  # The side events a decision names on top of a row's events: cost.reported
  # on a verdict (milestone 2 plan EN-12).
  SIDE_EVENTS = { "pass_review" => %w[cost.reported] }.freeze

  setup do
    @scenario = Scenario.new
    @owner = @scenario.owner
    @builder = @scenario.seat(role: "builder", credential: @scenario.credential)
    @reviewer = @scenario.seat(role: "reviewer", credential: @scenario.credential(provider: "codex"))
  end

  CASES = StateTableCases.for(T::Table::TASK_LOOP).select do |kase|
    !kase.invalid_state? && GATE_HOOKS.include?(kase.hook) && !kase.not_served? &&
      !kase.guard.include?("has_outward_action")
  end

  test "the gated rows are the four commands at the four hooks" do
    assert_equal %w[claim complete_contract pass_review submit], CASES.map(&:command).uniq.sort
    assert_equal GATE_HOOKS.sort, CASES.map(&:hook).uniq.sort
  end

  CASES.each do |kase|
    KINDS.each do |kind|
      test("gated row: #{kase.name}, #{kind.to_s.tr("_", " ")}") { assert_gated(kase, kind) }
    end
  end

  private

  def assert_gated(kase, kind)
    rule = rule_for(kase.hook, kind)
    with_jobs do
      caller, params, task = prepare(kase.command)
      outcome = command(kase.command, caller, params)
      check = RuleCheck.find_by!(rule_id: rule.id)
      send(:"assert_#{kind}", kase, outcome, task.reload, check)
    end
  end

  def assert_app_passes(kase, outcome, task, check)
    assert outcome.completed?, outcome.refusal&.code
    assert_equal [ "check.finished" ] + kase.events + SIDE_EVENTS.fetch(kase.command, []), types
    assert_equal [ "passed", nil ], [ check.result, check.pending_transition_id ]
    assert_equal kase.to, task.state
  end

  def assert_app_fails(kase, outcome, task, check)
    assert_equal "failed", check.result
    case Leverage::Contract.hooks.fetch("hooks").find { |hook| hook["hook"] == kase.hook }.fetch("failed_gate")
    when "hold_contract_incomplete"
      assert outcome.completed?, "a failed gate at ready to start reads completed (RD-10)"
      assert_equal %w[check.finished task.contract_changed hold.opened], types
      assert_equal [ "backlog", 1 ], [ task.state, task.contract_version ]
      assert Hold.exists?(task_id: task.id, reason: "contract_incomplete", rule_id: check.rule_id, rule_check_id: check.id,
        closed_at: nil)
    when "refuse"
      assert outcome.refused?
      assert_equal [ "blocked_by_rule", check.rule_id ], [ outcome.refusal.code, outcome.refusal.rule_id ]
      assert_equal [ "check.finished" ], types, "a refused command commits its rule check (RE-7)"
      assert_equal kase.from, task.state
    when "failed_review"
      assert outcome.completed?
      assert_equal %w[check.finished review.failed criterion.reopened cost.reported], types
      failed = written.find { |event| event.type == "review.failed" }
      assert_equal check.id, failed.payload["failed_rule_check_id"]
      assert_equal "working", task.state, "the free builder gets the rework"
    else flunk "no failed-gate effect for #{kase.hook}"
    end
  end

  def assert_model_blocks(kase, outcome, task, check)
    assert_equal :pending, outcome.outcome
    assert_equal %w[check.queued job.queued], types
    pending = PendingTransition.find_by!(task_id: task.id, state: "pending")
    assert_equal [ kase.command, @key, check.pending_transition_id ], [ pending.command, pending.command_key, pending.id ]
    assert_equal kase.from, task.state
    assert_equal pending.id, Command.find_by!(key: @key).pending_transition_id
    assert_equal "pending", Command.find_by!(key: @key).outcome
  end

  def assert_model_warns(kase, outcome, task, check)
    assert outcome.completed?, outcome.refusal&.code
    assert_equal %w[check.queued job.queued] + kase.events + SIDE_EVENTS.fetch(kase.command, []), types
    assert_nil check.pending_transition_id
    assert_nil PendingTransition.find_by(task_id: task.id)
    assert_equal kase.to, task.state
  end

  def rule_for(hook, kind)
    rule = case kind
    when :app_passes, :app_fails then app_rule(hook)
    when :model_blocks then custom_rule(hook)
    when :model_warns then custom_rule(hook, on_fail: "warn")
    end
    gating([ rule, ({ app_result: "failed" } if kind == :app_fails) ])
    rule
  end

  def prepare(command)
    case command
    when "complete_contract"
      task = @scenario.task(state: "backlog")
      [ @owner, contract_params(task), task ]
    when "claim"
      [ @builder, {}, @scenario.task(state: "ready") ]
    when "submit"
      task = ready_to_submit(@builder)
      [ @builder, submit_params(task), task ]
    when "pass_review"
      task, review = ready_for_verdict(@builder, @reviewer)
      [ @reviewer, pass_params(review), task ]
    end
  end
end
