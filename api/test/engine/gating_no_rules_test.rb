require "test_helper"
require_relative "../support/gating_conformance"

# Leverage::Gating::NoRules, the gating a workspace with no rules has in
# milestone 2 (plan EN-5): every hook completes with nothing planned, no
# briefing rule, every provider allowed and nothing filtered from a claim.
# It runs the shared conformance suite's rule-free cases; the cases that
# need a rule (a gate, a policy, a pending transition, an action) cannot be
# built in a workspace with no rules and are skipped with that reason.
class GatingNoRulesTest < ActiveSupport::TestCase
  include GatingConformance

  RULE_FREE = %i[provider_rule_off].freeze

  setup do
    @scenario = Scenario.new
    @seat = @scenario.seat
    @task = @scenario.task(state: "ready")
  end

  def no_rules = Leverage::Gating::NoRules.new

  def build_scenario(name)
    skip "#{name} needs a rule, and rules arrive in milestone 4 (EN-4, EN-5)" unless RULE_FREE.include?(name)

    Leverage::Gating.implementation = no_rules
    { task_id: @task.id, provider: "claude" }
  end

  def request(hook)
    Leverage::Gating::Request.new(workspace_id: @scenario.workspace_id, task_id: @task.id, project_id: nil, hook: hook,
      round: 0, subject_kind: nil, subject_id: nil, requester_kind: "seat", requester_id: @seat.id, command_key: "k",
      inputs: {})
  end

  test "every hook completes with nothing planned" do
    Leverage::Contract.registry.fetch("hooks").each do |hook|
      evaluation = no_rules.evaluate(request(hook))
      assert_equal :completed, evaluation.outcome, hook
      assert_equal [ [] ] * 8, evaluation.to_h.except(:outcome).values, hook
    end
  end

  test "an unknown hook is a mistake" do
    assert_raises(ArgumentError) { no_rules.evaluate(request("task.made_up")) }
  end

  test "there are no briefing rules, no built-by providers, and every provider is allowed" do
    assert_equal [], no_rules.briefing_rules(task_id: @task.id, seat_id: @seat.id)
    assert_equal [], no_rules.built_by_providers(task_id: @task.id)
    Leverage::Contract.registry.fetch("credential_providers").each do |entry|
      assert no_rules.provider_allowed?(task_id: @task.id, provider: entry.fetch("provider"))
    end
  end

  test "a claim filters nothing out" do
    %i[task review].each do |kind|
      filter = no_rules.claimable_filter(seat_id: @seat.id, kind: kind)
      assert_equal [ [], [] ], [ filter.excluded_task_ids, filter.excluded_review_ids ]
    end
    assert_raises(ArgumentError) { no_rules.claimable_filter(seat_id: @seat.id, kind: :job) }
  end

  test "nothing can be pending, so nothing can be gated again" do
    assert_raises(Leverage::Gating::NoRules::NothingPending) do
      no_rules.reenter(pending_transition_id: SecureRandom.uuid, trigger: nil)
    end
    assert_raises(Leverage::Gating::NoRules::NothingPending) do
      no_rules.reenter_action(action_id: SecureRandom.uuid, trigger: nil)
    end
  end

  test "the application's gating is NoRules, set by its initializer" do
    Leverage::Gating.implementation = nil
    Rails.application.reloader.prepare!
    assert_instance_of Leverage::Gating::NoRules, Leverage::Gating.implementation
  end

  test "NoRules reads nothing and writes nothing" do
    statements = writes_during do
      no_rules.evaluate(request("task.before_claim"))
      no_rules.briefing_rules(task_id: @task.id, seat_id: @seat.id)
      no_rules.claimable_filter(seat_id: @seat.id, kind: :task)
    end
    assert_empty statements
  end
end
