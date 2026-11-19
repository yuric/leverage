require_relative "contract_helper"
require_relative "../support/gating_conformance"

# Leverage::Gating, the in-process interface between the transition function
# and rule gating (plan §1.2). The shared conformance suite runs on the
# stand-in here; track B runs it on its own implementation.
class GatingTest < Minitest::Test
  include ContractTestHelpers
  include GatingConformance

  TASK = "00000000-0000-4000-8000-0000000000a1".freeze
  OTHER_TASK = "00000000-0000-4000-8000-0000000000a2".freeze
  SEAT = "00000000-0000-4000-8000-0000000000b1".freeze
  RULE = "00000000-0000-4000-8000-0000000000c1".freeze
  OTHER_RULE = "00000000-0000-4000-8000-0000000000c2".freeze
  THIRD_RULE = "00000000-0000-4000-8000-0000000000c3".freeze
  TRANSITION = "00000000-0000-4000-8000-0000000000d1".freeze
  CHECK = "00000000-0000-4000-8000-0000000000e1".freeze
  OTHER_CHECK = "00000000-0000-4000-8000-0000000000e2".freeze
  SUBMIT_INPUTS = { "contract_version" => 1, "criteria" => [], "handoff_note" => "ready" }.freeze

  def stand_in(world)
    Leverage::Gating.implementation = Leverage::Gating::StandIn.new(**world)
  end

  def rule(id = RULE, **fields)
    { id: id, version_id: "#{id[0..-3]}ff", version: 1, hook: "task.before_submit", kind: "gate", checker: "model",
      on_fail: "block", route: "builder", enabled: true, scope: "covers" }.merge(fields)
  end

  def submit_request
    Leverage::Gating::Request.new(workspace_id: SEAT, task_id: TASK, project_id: nil, hook: "task.before_submit",
      round: 0, subject_kind: nil, subject_id: nil, requester_kind: "seat", requester_id: SEAT,
      command_key: "key-1", inputs: SUBMIT_INPUTS)
  end

  def transition(*checks)
    { TRANSITION => { task_id: TASK, held: false, inputs_changed: false, checks: checks } }
  end

  def trigger(kind = :check_finished) = Leverage::Gating::Trigger.new(kind: kind, rule_check_id: CHECK)

  def build_scenario(name)
    case name
    when :blocking_model_gate
      stand_in(rules: [ rule ])
      { request: submit_request }
    when :warn_model_gate
      stand_in(rules: [ rule(on_fail: "warn") ])
      { request: submit_request }
    when :app_gate_fails
      stand_in(rules: [ rule(checker: "app", app_result: "failed", route: "owner") ])
      { request: submit_request, rule_id: RULE, route: "owner" }
    when :rule_out_of_scope
      stand_in(rules: [ rule(scope: "not_covered") ])
      { request: submit_request, rule_id: RULE }
    when :checks_withdrawn_or_overridden
      stand_in(rules: [ rule, rule(OTHER_RULE) ],
        transitions: transition({ id: CHECK, rule_id: RULE, result: "withdrawn", overridden: false },
          { id: OTHER_CHECK, rule_id: OTHER_RULE, result: "failed", overridden: true }))
      { pending_transition_id: TRANSITION, trigger: trigger(:check_overridden) }
    when :one_check_failed
      stand_in(rules: [ rule(route: "builder"), rule(OTHER_RULE) ],
        transitions: transition({ id: CHECK, rule_id: RULE, result: "failed", overridden: false },
          { id: OTHER_CHECK, rule_id: OTHER_RULE, result: "passed", overridden: false }))
      { pending_transition_id: TRANSITION, trigger: trigger, rule_id: RULE, route: "builder" }
    when :check_error
      stand_in(rules: [ rule ], transitions: transition({ id: CHECK, rule_id: RULE, result: "error", overridden: false }))
      { pending_transition_id: TRANSITION, trigger: trigger(:check_timed_out) }
    when :provider_rule_off, :provider_rule_on
      provider_rule = rule(hook: "review.assign", kind: "policy", checker: "app", on_fail: nil, route: nil,
        enabled: name == :provider_rule_on)
      stand_in(rules: [ provider_rule ], built_by: { TASK => %w[claude] })
      { task_id: TASK, provider: "claude_api", built_provider: "claude_api", other_provider: "codex" }
    when :claim_gate_failed_and_overridden
      claim_rule = rule(hook: "task.before_claim")
      stand_in(rules: [ claim_rule ], claim_checks: [
        { task_id: TASK, seat_id: SEAT, rule_id: RULE, result: "failed", overridden: false, current: true },
        { task_id: OTHER_TASK, seat_id: SEAT, rule_id: RULE, result: "failed", overridden: true, current: true }
      ])
      { seat_id: SEAT, failed_task_id: TASK, overridden_task_id: OTHER_TASK }
    when :briefing
      stand_in(rules: [ rule, rule(OTHER_RULE, scope: "checker_decides"), rule(THIRD_RULE, enabled: false) ])
      { task_id: TASK, seat_id: SEAT, covering_rule_id: RULE, checker_decides_rule_id: OTHER_RULE,
        disabled_rule_id: THIRD_RULE }
    else
      raise ArgumentError, "no scenario #{name}"
    end
  end

  def test_the_module_answers_every_documented_call
    expected = {
      evaluate: [ [ :req, :request ] ],
      reenter: [ [ :keyreq, :pending_transition_id ], [ :keyreq, :trigger ] ],
      input_hash: [ [ :keyreq, :hook ], [ :keyreq, :inputs ] ],
      briefing_rules: [ [ :keyreq, :task_id ], [ :keyreq, :seat_id ], [ :key, :review_id ] ],
      built_by_providers: [ [ :keyreq, :task_id ] ],
      provider_allowed?: [ [ :keyreq, :task_id ], [ :keyreq, :provider ] ],
      claimable_filter: [ [ :keyreq, :seat_id ], [ :keyreq, :kind ] ],
      "implementation=": [ [ :req, :impl ] ],
      implementation: []
    }
    expected.each do |name, parameters|
      assert_equal parameters, Leverage::Gating.method(name).parameters, name
    end
  end

  def test_a_call_with_no_implementation_set_raises
    Leverage::Gating.implementation = nil
    assert_raises(Leverage::Gating::NotConfigured) { Leverage::Gating.built_by_providers(task_id: TASK) }
  end

  def test_value_objects_are_frozen_data
    %i[Request Evaluation PlannedCheck PlannedJob PlannedHold Failure Effect Decision Trigger BriefingPart ClaimFilter].each do |name|
      assert_operator Leverage::Gating.const_get(name), :<, Data, name
    end
    build_scenario(:blocking_model_gate)
    evaluation = Leverage::Gating.evaluate(submit_request)
    [ evaluation, evaluation.checks, evaluation.jobs, evaluation.failures, evaluation.checks.first,
      submit_request, submit_request.inputs ].each { |value| assert_predicate value, :frozen? }
  end

  def test_value_objects_refuse_values_outside_their_lists
    assert_raises(ArgumentError) { Leverage::Gating::Trigger.new(kind: :check_lost, rule_check_id: CHECK) }
    assert_raises(ArgumentError) do
      Leverage::Gating::Decision.new(action: :maybe, failures: [], effects: [], holds_to_open: [], holds_to_close: [],
        checks_to_withdraw: [])
    end
    assert_raises(ArgumentError) { Leverage::Gating::PlannedHold.new(reason: "nap", rule_id: RULE, rule_check_id: CHECK) }
    assert_raises(ArgumentError) { Leverage::Gating::Effect.new(rule_id: RULE, hook: "review.assign", effect: "approved") }
    assert_raises(ArgumentError) { Leverage::Gating::Failure.new(rule_id: RULE, rule_check_ref: 0, reason: nil, route: "anyone") }
    assert_raises(ArgumentError) { Leverage::Gating::BriefingPart.new(kind: :poem, id: RULE, version: 1, may_apply: false) }
  end

  def test_the_stand_in_raises_for_an_unknown_hook
    build_scenario(:blocking_model_gate)
    request = submit_request.with(hook: "task.before_lunch")
    assert_raises(ArgumentError) { Leverage::Gating.evaluate(request) }
  end

  def test_the_stand_in_uses_no_database
    source = File.read(File.expand_path("../../lib/leverage/gating/stand_in.rb", __dir__))
    refute_match(/ActiveRecord|ApplicationRecord/, source)
  end

  def test_input_hash_matches_golden_vectors
    vectors = {
      [ "task.before_claim", { "seat_id" => "7d2c5a10-0000-4000-8000-000000000001", "contract_version" => 3 } ] =>
        "56ea05844c693f728fab06754671bd6913a201c14ea690da2c4cfb38ae923b60",
      [ "task.before_submit", {
        "handoff_note" => "Done.\nSee \"notes\".", "contract_version" => 2,
        "criteria" => [
          { "state" => "passed", "id" => "7d2c5a10-0000-4000-8000-0000000000c1",
            "evidence" => [ [ "link", "https://example.test/proof" ], [ "note", "section 2" ] ] },
          { "state" => "open", "id" => "7d2c5a10-0000-4000-8000-0000000000c2", "evidence" => [] }
        ]
      } ] => "f32360ee3a4bb2e4ea3d6bf6f6865606e397e3db0fa6ef02cec14622fafa6e90",
      [ "question.asked", { "question" => "Café — naïve? 日本" } ] =>
        "a225839002287c751b80fa72223651f9ac780107e8d17bcc9ab7c1f61fb9dcd6",
      [ "task.before_done", { "contract_version" => 1, "verdict" => "passed", "notes" => nil, "evidence" => {} } ] =>
        "0edcf6eecabb1d52225b093a7ed25acc6dcbae4d2290102ce5a010d141b3b53a"
    }
    vectors.each do |(hook, inputs), hex|
      assert_equal hex, Leverage::Gating.input_hash(hook: hook, inputs: inputs), hook
    end
  end

  def test_canonical_json_sorts_keys_by_code_point_with_no_whitespace
    canonical = Leverage::Gating::CanonicalJson
    assert_equal '{"Z":null,"a":[1,[2,{}]],"b":1,"é":true}',
      canonical.dump({ "b" => 1, "a" => [ 1, [ 2, {} ] ], "é" => true, "Z" => nil })
    assert_equal "{}", canonical.dump({})
    assert_equal "44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a",
      Digest::SHA256.hexdigest(canonical.dump({}))
  end

  def test_canonical_json_refuses_values_with_no_single_form
    canonical = Leverage::Gating::CanonicalJson
    [ 1.5, Time.at(0), :symbol, { key: 1 }, [ 1.0 ], Object.new, "\xFF".dup.force_encoding("UTF-8") ].each do |value|
      assert_raises(ArgumentError, value.inspect) { canonical.dump(value) }
    end
  end

  def test_input_hash_takes_exactly_the_hook_hashed_inputs
    assert_raises(ArgumentError) { Leverage::Gating.input_hash(hook: "task.before_claim", inputs: { "seat_id" => SEAT }) }
    assert_raises(ArgumentError) { Leverage::Gating.input_hash(hook: "task.before_lunch", inputs: {}) }
    assert_raises(ArgumentError) do
      Leverage::Gating.input_hash(hook: "task.before_claim", inputs: { "seat_id" => SEAT, "contract_version" => 1.0 })
    end
  end

  def test_a_policy_records_an_applied_row_with_its_effect
    stand_in(rules: [ rule(hook: "question.asked", kind: "policy", checker: "app", on_fail: nil, route: nil,
      effect: "to_owner") ])
    request = submit_request.with(hook: "question.asked", subject_kind: "question", subject_id: CHECK,
      inputs: { "question" => "Which branch?" })
    evaluation = Leverage::Gating.evaluate(request)
    assert_equal :completed, evaluation.outcome
    assert_equal [ "applied" ], evaluation.checks.map(&:result)
    assert_equal [ "to_owner" ], evaluation.effects.map(&:effect)
  end

  def test_the_claim_filter_takes_only_tasks_and_reviews
    build_scenario(:claim_gate_failed_and_overridden)
    assert_raises(ArgumentError) { Leverage::Gating.claimable_filter(seat_id: SEAT, kind: :job) }
    stand_in(rules: [ rule(hook: "review.assign", kind: "policy", checker: "app", on_fail: nil, route: nil) ],
      built_by: { TASK => %w[claude] }, past_holders: { OTHER_TASK => [ SEAT ] },
      reviews: { "r1" => TASK, "r2" => OTHER_TASK, "r3" => "t3" }, seat_providers: { SEAT => "claude" })
    assert_equal %w[r1 r2], Leverage::Gating.claimable_filter(seat_id: SEAT, kind: :review).excluded_review_ids.sort
  end
end
