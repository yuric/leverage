require "test_helper"
require_relative "rule_support"

# Entries::EnableRule (PRD L379; milestone 4 plan RD-3, RD-5): the owner
# turns a rule on. It does not apply to a request already made, so no
# check is touched. A rule already on, or removed, is invalid_state.
class EnableRuleTest < ActiveSupport::TestCase
  include RuleSupport

  setup { use_scenario }

  test "it turns the rule on with rule.enabled and writes no version" do
    rule = scenario.rule(enabled: false)

    outcome, events = owner_run("enable_rule", { "id" => rule.id })

    assert_completed(outcome)
    assert rule.reload.enabled
    assert_equal 1, rule.current_version
    assert_equal [ [ "rule.enabled", {}, "owner", rule.id ] ],
      events.map { |event| [ event.type, event.payload, event.actor_kind, event.subject_id ] }
  end

  test "a rule that is on already, or removed, is invalid_state and writes nothing" do
    on = scenario.rule(enabled: true)
    removed = scenario.rule(enabled: false)
    removed.update!(removed_at: scenario.database_now)

    [ on, removed ].each do |rule|
      outcome, events = owner_run("enable_rule", { "id" => rule.id })
      assert_refused("invalid_state", outcome)
      assert_empty events
    end
    refute removed.reload.enabled
  end

  test "a rule of another workspace is 404" do
    other = Scenario.new
    other.owner

    assert_raises(T::NotFound) { owner_command("enable_rule", { "id" => other.rule(enabled: false).id }) }
  end
end
