require_relative "rules/rules_test_support"
require_relative "../support/gating_conformance"

# Leverage::Rules::Engine against the gating conformance suite every
# implementation of Leverage::Gating passes (milestone 4 plan RE-1, WP3):
# the scenarios are rows in the database, built through Scenario, where the
# stand-in's are an in-memory world (test/contract/gating_test.rb).
class GatingEngineTest < ActiveSupport::TestCase
  include Leverage::Rules::TestSupport
  include GatingConformance

  NOTE = { "handoff_note" => "A made-up note." }.freeze

  def use_engine
    Leverage::Gating.implementation = Leverage::Rules::Engine.new
  end

  def working_task
    @working_task ||= scenario.task(state: "working", builder: (@builder = scenario.seat))
  end

  def submit_request = request_for(working_task, "task.before_submit", params: NOTE, requester: @builder)

  def submit_hash = Leverage::Gating.input_hash(hook: "task.before_submit", inputs: submit_request.inputs)

  # A pending submit whose rules each have the check given: [rule, result,
  # overridden].
  def pending_with(*checks)
    rules = checks.map(&:first)
    pending = scenario.pending_transition(working_task, command: "submit", requester: @builder, params: NOTE,
      frozen_rule_version_ids: rules.map { |rule| scenario.current_version(rule).id })
    rows = checks.map do |rule, result, overridden|
      row = scenario.rule_check(working_task, rule: rule, result: result, pending: pending, input_hash: submit_hash)
      overridden ? override(row) : row
    end
    [ pending, rows ]
  end

  def approval_policy = scenario.rule(key: "orchestrator_approves_actions", origin: "shipped")

  def action_gate(**fields) = model_gate("action.requested", route: "owner", **fields)

  def action_request(task, made)
    request_for(task, "action.requested", subject: made, params: { "aid" => made.id }).with(requester_kind: "app",
      requester_id: nil, command_key: nil)
  end

  def action_check(task, made, rule, result, overridden: false)
    hash = Leverage::Gating.input_hash(hook: "action.requested", inputs: action_request(task, made).inputs)
    row = scenario.rule_check(task, rule: rule, result: result, subject: made, input_hash: hash)
    overridden ? override(row) : row
  end

  def build_scenario(name)
    use_engine
    case name
    when :blocking_model_gate
      model_gate("task.before_submit")
      { request: submit_request }
    when :warn_model_gate
      model_gate("task.before_submit", on_fail: "warn")
      { request: submit_request }
    when :app_gate_fails
      rule = app_gate("task.before_submit", "minimum_criteria_count", parameters: { "minimum_count" => 5 }, route: "owner")
      { request: submit_request, rule_id: rule.id, route: "owner" }
    when :rule_out_of_scope
      rule = model_gate("task.before_submit", scope_kind: "named_projects", scope_values: [ scenario.project.id ])
      { request: submit_request, rule_id: rule.id }
    when :checks_withdrawn_or_overridden
      pending, = pending_with([ model_gate("task.before_submit"), "withdrawn" ], [ model_gate("task.before_submit"), "failed", true ])
      { pending_transition_id: pending.id, trigger: trigger(:check_overridden) }
    when :one_check_failed
      rule = model_gate("task.before_submit", route: "builder")
      pending, = pending_with([ rule, "failed" ], [ model_gate("task.before_submit"), "passed" ])
      { pending_transition_id: pending.id, trigger: trigger, rule_id: rule.id, route: "builder" }
    when :check_error
      pending, = pending_with([ model_gate("task.before_submit"), "error" ])
      { pending_transition_id: pending.id, trigger: trigger(:check_timed_out) }
    when :provider_rule_off, :provider_rule_on
      scenario.with_shipped_rules(off: name == :provider_rule_on ? [] : [ "different_provider_review" ])
      task = scenario.task(state: "in_review", builder: scenario.seat(credential: scenario.credential(provider: "claude")))
      { task_id: task.id, provider: "claude_api", built_provider: "claude_api", other_provider: "codex" }
    when :claim_gate_failed_and_overridden
      rule = model_gate("task.before_claim")
      seat = scenario.seat
      failed, overridden = Array.new(2) { scenario.task(state: "ready") }
      [ failed, overridden ].each do |task|
        row = scenario.rule_check(task, rule: rule, result: "failed", subject: seat,
          input_hash: hash_for(task, "task.before_claim", subject: seat))
        override(row) if task == overridden
      end
      { seat_id: seat.id, failed_task_id: failed.id, overridden_task_id: overridden.id }
    when :action_gate_pending
      approval = approval_policy
      action_gate
      { request: action_request(working_task, action(working_task)), approval_rule_id: approval.id }
    when :action_gate_fails_at_once
      approval = approval_policy
      gate = app_gate("action.requested", "minimum_criteria_count", parameters: { "minimum_count" => 5 })
      { request: action_request(working_task, action(working_task)), rule_id: gate.id, approval_rule_id: approval.id }
    when :action_no_gate
      approval = approval_policy
      { request: action_request(working_task, action(working_task)), approval_rule_id: approval.id }
    when :action_gates_passed, :action_gate_failed
      approval = approval_policy
      first = action_gate
      second = action_gate
      made = action(working_task)
      if name == :action_gates_passed
        action_check(working_task, made, first, "passed")
        action_check(working_task, made, second, "failed", overridden: true)
      else
        action_check(working_task, made, first, "failed")
        action_check(working_task, made, second, "not_applicable")
      end
      { action_id: made.id, trigger: trigger, rule_id: first.id, approval_rule_id: approval.id }
    when :briefing
      covering = model_gate("task.before_submit")
      deciding = model_gate("task.before_ready", scope_kind: "checker_decides")
      disabled = model_gate("task.before_submit", enabled: false)
      { task_id: working_task.id, seat_id: @builder.id, covering_rule_id: covering.id, checker_decides_rule_id: deciding.id,
        disabled_rule_id: disabled.id }
    else
      raise ArgumentError, "no scenario #{name}"
    end
  end

  test "approval and gate jobs are scoped to the action within the same task" do
    approval = scenario.rule(key: "orchestrator_approves_actions", origin: "shipped", scope_kind: "action_kinds",
      scope_values: [ "publish" ])
    gate = action_gate(scope_kind: "action_kinds", scope_values: [ "send" ])
    publishing = action(working_task, kind: "publish")
    sending = action(working_task, kind: "send", position: 2)

    evaluation = gating.evaluate(action_request(working_task, publishing))
    assert_equal [ [ gate.id, "not_applicable" ], [ approval.id, nil ] ], evaluation.checks.map { |check| [ check.rule_id, check.result ] }
    assert_equal [ [ "approval", 1, "orchestrator" ] ], evaluation.jobs.map { |job| [ job.kind, job.rule_check_ref, job.seat_role ] }
    assert_empty evaluation.deferred_rule_ids

    evaluation = gating.evaluate(action_request(working_task, sending))
    assert_equal :pending, evaluation.outcome
    assert_equal [ gate.id ], evaluation.checks.map(&:rule_id)
    assert_equal [ [ "rule_check", 0 ] ], evaluation.jobs.map { |job| [ job.kind, job.rule_check_ref ] }
    assert_empty evaluation.deferred_rule_ids

    settled = action_check(working_task, sending, gate, "passed")
    decision = gating.reenter_action(action_id: sending.id, trigger: trigger(:check_finished, settled))
    assert_equal :complete, decision.action
    assert_equal [ [ approval.id, "not_applicable" ] ], decision.checks.map { |check| [ check.rule_id, check.result ] }
    assert_empty decision.jobs
  end

  test "reentering an action considers only gate checks for its current round" do
    approval_policy
    gate = action_gate
    made = action(working_task)
    action_check(working_task, made, gate, "failed")
    working_task.update!(round: working_task.round + 1)
    check = action_check(working_task, made, gate, "passed")

    decision = gating.reenter_action(action_id: made.id, trigger: trigger(:check_finished, check))
    assert_equal :complete, decision.action
    assert_equal [ "approval" ], decision.jobs.map(&:kind)
  end

  test "an outward action whose gate still runs, or ended in error, waits; the error under check_error" do
    use_engine
    approval_policy
    gate = action_gate
    made = action(working_task)
    action_check(working_task, made, gate, nil)

    decision = Leverage::Gating.reenter_action(action_id: made.id, trigger: trigger)
    assert_equal [ :keep_pending, [] ], [ decision.action, decision.holds_to_open ]

    other = action(working_task, position: 2, description: "Publish another made-up page.")
    errored = action_check(working_task, other, gate, "error")
    decision = Leverage::Gating.reenter_action(action_id: other.id, trigger: trigger(:check_timed_out, errored))
    assert_equal :keep_pending, decision.action
    assert_equal [ [ "check_error", errored.id ] ], decision.holds_to_open.map { |hold| [ hold.reason, hold.rule_check_id ] }
  end
end
