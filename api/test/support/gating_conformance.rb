require "active_support"
require "active_support/notifications"

# The tests every implementation of Leverage::Gating must pass: the stand-in
# now (test/contract/gating_test.rb), and track B's implementation when it
# replaces it. They test what gating decides, not how.
#
# A test class includes this module and defines build_scenario(name). It sets
# up the named situation (rows in the database for a real implementation, an
# in-memory world for the stand-in), sets Leverage::Gating.implementation, and
# returns a Hash with the keys listed for that scenario:
#
# :blocking_model_gate   An enabled model-checked gate, on_fail block, whose
#                        fixed scope covers the task. Keys: :request.
# :warn_model_gate       The same rule with on_fail warn. Keys: :request.
# :app_gate_fails        An enabled app-checked gate, on_fail block, whose
#                        checker fails. Keys: :request, :rule_id, :route.
# :rule_out_of_scope     An enabled gate whose fixed scope does not cover the
#                        task. Keys: :request, :rule_id.
# :checks_withdrawn_or_overridden
#                        A pending transition whose checks are each withdrawn
#                        or overridden. Keys: :pending_transition_id, :trigger.
# :one_check_failed      A pending transition one of whose blocking checks has
#                        failed. Keys: :pending_transition_id, :trigger,
#                        :rule_id, :route.
# :check_error           A pending transition whose blocking check ended in
#                        error. Keys: :pending_transition_id, :trigger.
# :provider_rule_off     The provider rule is off and :provider has built the
#                        task. Keys: :task_id, :provider.
# :provider_rule_on      The provider rule is on; :built_provider has built the
#                        task and :other_provider (another provider group) has
#                        not. Keys: :task_id, :built_provider, :other_provider.
# :claim_gate_failed_and_overridden
#                        The seat failed task.before_claim on :failed_task_id
#                        and its failed check on :overridden_task_id was
#                        overridden; both on current inputs. Keys: :seat_id,
#                        :failed_task_id, :overridden_task_id.
# :action_gate_pending   At action.requested, an enabled model-checked gate,
#                        on_fail block, and the approval policy (a model
#                        policy), both covering the action. Keys: :request,
#                        :approval_rule_id.
# :action_gate_fails_at_once
#                        At action.requested, an app-checked gate, on_fail
#                        block, whose checker fails, and the approval policy.
#                        Keys: :request, :rule_id, :approval_rule_id.
# :action_no_gate        At action.requested, the approval policy and no gate.
#                        Keys: :request, :approval_rule_id.
# :action_gates_passed   An action whose gate checks have each passed, not
#                        applied, been withdrawn or been overridden, with the
#                        approval policy on. Keys: :action_id, :trigger,
#                        :approval_rule_id.
# :action_gate_failed    An action one of whose gate checks has failed, with
#                        the approval policy on. Keys: :action_id, :trigger,
#                        :rule_id, :approval_rule_id.
# :briefing              The task has an enabled rule whose fixed scope covers
#                        it, an enabled "let the checker decide" rule and a
#                        disabled rule. Keys: :task_id, :seat_id, :covering_rule_id,
#                        :checker_decides_rule_id, :disabled_rule_id.
module GatingConformance
  def teardown
    Leverage::Gating.implementation = nil
    super
  end

  def gating = Leverage::Gating

  # The SQL statements the block issued that are not reads, as Active Record
  # reports them. Schema and transaction statements are not the call's own.
  def writes_during
    statements = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      next if %w[SCHEMA TRANSACTION].include?(payload[:name])

      statements << payload[:sql] unless payload[:sql].match?(/\A\s*(SELECT|WITH)\b/i)
    end
    yield
    statements
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  def test_conformance_a_blocking_model_gate_makes_the_result_pending
    scenario = build_scenario(:blocking_model_gate)
    evaluation = gating.evaluate(scenario[:request])
    assert_equal :pending, evaluation.outcome
    assert(evaluation.checks.any? { |check| check.checker == "model" && check.result.nil? })
    assert_includes evaluation.jobs.map(&:kind), "rule_check"
    assert_empty evaluation.failures
  end

  def test_conformance_a_warn_model_gate_never_makes_the_result_pending
    scenario = build_scenario(:warn_model_gate)
    evaluation = gating.evaluate(scenario[:request])
    assert_equal :completed, evaluation.outcome
    assert_includes evaluation.jobs.map(&:kind), "rule_check", "a warn check is still queued (plan RC-16)"
  end

  def test_conformance_a_failed_app_gate_completes_with_a_routed_failure
    scenario = build_scenario(:app_gate_fails)
    evaluation = gating.evaluate(scenario[:request])
    assert_equal :completed, evaluation.outcome
    assert_equal [ [ scenario[:rule_id], scenario[:route] ] ], evaluation.failures.map { |failure| [ failure.rule_id, failure.route ] }
    assert_empty evaluation.jobs
  end

  def test_conformance_a_rule_out_of_scope_is_not_applicable_and_runs_nothing
    scenario = build_scenario(:rule_out_of_scope)
    evaluation = gating.evaluate(scenario[:request])
    assert_equal :completed, evaluation.outcome
    check = evaluation.checks.find { |planned| planned.rule_id == scenario[:rule_id] }
    assert_equal "not_applicable", check.result
    assert_empty evaluation.jobs
    assert_empty evaluation.failures
  end

  def test_conformance_withdrawn_or_overridden_checks_complete_the_transition
    scenario = build_scenario(:checks_withdrawn_or_overridden)
    decision = gating.reenter(pending_transition_id: scenario[:pending_transition_id], trigger: scenario[:trigger])
    assert_equal :complete, decision.action
    assert_empty decision.failures
  end

  def test_conformance_a_failed_check_refuses_with_a_routed_failure
    scenario = build_scenario(:one_check_failed)
    decision = gating.reenter(pending_transition_id: scenario[:pending_transition_id], trigger: scenario[:trigger])
    assert_equal :refuse, decision.action
    assert_equal [ [ scenario[:rule_id], scenario[:route] ] ], decision.failures.map { |failure| [ failure.rule_id, failure.route ] }
  end

  def test_conformance_an_errored_check_keeps_the_transition_pending_under_a_hold
    scenario = build_scenario(:check_error)
    decision = gating.reenter(pending_transition_id: scenario[:pending_transition_id], trigger: scenario[:trigger])
    assert_equal :keep_pending, decision.action
    assert_includes decision.holds_to_open.map(&:reason), "check_error"
  end

  # PRD L138: at action.requested the gates run first, and the approval
  # policy runs only once every gate has passed, did not apply, was withdrawn
  # or was overridden. Checks at action.requested are not pending
  # transitions (L384), so they are gated again by action.
  def test_conformance_the_approval_policy_waits_for_the_gates_at_action_requested
    scenario = build_scenario(:action_gate_pending)
    evaluation = gating.evaluate(scenario[:request])
    assert_equal :pending, evaluation.outcome
    refute_includes evaluation.checks.map(&:rule_id), scenario[:approval_rule_id]
    refute_includes evaluation.jobs.map(&:kind), "approval"
    assert_equal [ scenario[:approval_rule_id] ], evaluation.deferred_rule_ids
  end

  def test_conformance_a_failed_gate_at_action_requested_runs_no_approval_policy
    scenario = build_scenario(:action_gate_fails_at_once)
    evaluation = gating.evaluate(scenario[:request])
    assert_equal [ scenario[:rule_id] ], evaluation.failures.map(&:rule_id)
    refute_includes evaluation.checks.map(&:rule_id), scenario[:approval_rule_id]
    refute_includes evaluation.jobs.map(&:kind), "approval"
    assert_empty evaluation.deferred_rule_ids
  end

  def test_conformance_with_no_gate_the_approval_policy_runs_at_once
    scenario = build_scenario(:action_no_gate)
    evaluation = gating.evaluate(scenario[:request])
    assert_includes evaluation.checks.map(&:rule_id), scenario[:approval_rule_id]
    assert_includes evaluation.jobs.map(&:kind), "approval"
    assert_empty evaluation.deferred_rule_ids
  end

  def test_conformance_an_action_whose_gates_passed_plans_the_approval_policy
    scenario = build_scenario(:action_gates_passed)
    decision = gating.reenter_action(action_id: scenario[:action_id], trigger: scenario[:trigger])
    assert_equal :complete, decision.action
    assert_empty decision.failures
    assert_includes decision.checks.map(&:rule_id), scenario[:approval_rule_id]
    assert_includes decision.jobs.map(&:kind), "approval"
  end

  def test_conformance_an_action_whose_gate_failed_is_stopped_with_no_approval_policy
    scenario = build_scenario(:action_gate_failed)
    decision = gating.reenter_action(action_id: scenario[:action_id], trigger: scenario[:trigger])
    assert_equal :refuse, decision.action
    assert_equal [ scenario[:rule_id] ], decision.failures.map(&:rule_id)
    refute_includes decision.jobs.map(&:kind), "approval"
    refute_includes decision.checks.map(&:rule_id), scenario[:approval_rule_id]
  end

  def test_conformance_with_the_provider_rule_off_every_provider_is_allowed
    scenario = build_scenario(:provider_rule_off)
    assert gating.provider_allowed?(task_id: scenario[:task_id], provider: scenario[:provider])
  end

  def test_conformance_with_the_provider_rule_on_a_builder_provider_is_refused
    scenario = build_scenario(:provider_rule_on)
    refute gating.provider_allowed?(task_id: scenario[:task_id], provider: scenario[:built_provider])
    assert gating.provider_allowed?(task_id: scenario[:task_id], provider: scenario[:other_provider])
  end

  def test_conformance_the_claim_filter_skips_a_failed_task_but_not_an_overridden_one
    scenario = build_scenario(:claim_gate_failed_and_overridden)
    filter = gating.claimable_filter(seat_id: scenario[:seat_id], kind: :task)
    assert_includes filter.excluded_task_ids, scenario[:failed_task_id]
    refute_includes filter.excluded_task_ids, scenario[:overridden_task_id]
  end

  def test_conformance_the_briefing_holds_covering_rules_and_marks_checker_decides
    scenario = build_scenario(:briefing)
    parts = gating.briefing_rules(task_id: scenario[:task_id], seat_id: scenario[:seat_id])
    by_id = parts.to_h { |part| [ part.id, part ] }
    assert_equal false, by_id.fetch(scenario[:covering_rule_id]).may_apply
    assert_equal true, by_id.fetch(scenario[:checker_decides_rule_id]).may_apply
    refute by_id.key?(scenario[:disabled_rule_id])
    parts.each do |part|
      assert_equal :rule, part.kind
      assert_kind_of Integer, part.version
    end
  end

  # Each scenario is built before the block whose writes are counted: a
  # real implementation's scenario is rows in a database, which are
  # writes, and only the call's own statements are measured.
  def test_conformance_evaluation_and_reads_write_nothing
    statements = []
    scenario = build_scenario(:blocking_model_gate)
    statements += writes_during { gating.evaluate(scenario[:request]) }
    scenario = build_scenario(:provider_rule_on)
    statements += writes_during do
      gating.provider_allowed?(task_id: scenario[:task_id], provider: scenario[:built_provider])
      gating.built_by_providers(task_id: scenario[:task_id])
    end
    scenario = build_scenario(:claim_gate_failed_and_overridden)
    statements += writes_during { gating.claimable_filter(seat_id: scenario[:seat_id], kind: :task) }
    scenario = build_scenario(:briefing)
    statements += writes_during { gating.briefing_rules(task_id: scenario[:task_id], seat_id: scenario[:seat_id]) }
    assert_empty statements
  end
end
