require "test_helper"
require_relative "rule_support"

# Entries::RemoveRule (PRD L342, L379; milestone 4 plan RD-5, RD-45,
# DB-29): the owner removes a custom rule; what it has in flight is
# withdrawn as when it is turned off. A shipped rule is turned off, never
# removed, and a removed rule cannot be removed again: invalid_state.
class RemoveRuleTest < ActiveSupport::TestCase
  include RuleSupport

  setup { use_scenario }

  test "it marks the custom rule removed with rule.removed and withdraws its check in flight" do
    rule = scenario.rule(hook: "task.before_submit")
    builder = scenario.seat(role: "builder", credential: scenario.credential)
    task = scenario.task(state: "working", builder: builder)
    pending = scenario.pending_transition(task, command: "submit", requester: builder)
    check = scenario.rule_check(task, rule: rule, pending: pending)
    key = new_key

    calls = recording({ Leverage::RuleChecks => :withdraw, Leverage::PendingTransitions => :reenter }) do
      assert_completed(owner_command("remove_rule", { "id" => rule.id }, key: key))
    end

    refute_nil rule.reload.removed_at
    assert_equal [ "rule.removed" ], written_by(key).map(&:type)
    assert_equal [ check.id ], calls.fetch("RuleChecks.withdraw").map { |call| call.arguments[1].id }
    assert_equal [ pending.id ], calls.fetch("PendingTransitions.reenter").map { |call| call.arguments[1].id }
  end

  test "a shipped rule, or a removed one, is invalid_state and writes nothing (RD-5)" do
    shipped = scenario.with_shipped_rules.first
    removed = scenario.rule
    removed.update!(removed_at: scenario.database_now)

    [ shipped, removed ].each do |rule|
      outcome, events = owner_run("remove_rule", { "id" => rule.id })
      assert_refused("invalid_state", outcome)
      assert_empty events
    end
    assert_nil shipped.reload.removed_at
  end
end
