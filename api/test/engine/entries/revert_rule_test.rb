require "test_helper"
require_relative "rule_support"

# Entries::RevertRule (PRD L342; milestone 4 plan RD-5, RD-7, DB-29): the
# owner reverts a shipped rule: its shipped fields as a new version. A
# custom rule has no default: invalid_state.
class RevertRuleTest < ActiveSupport::TestCase
  include RuleSupport

  setup { use_scenario }

  test "it writes the shipped fields as the next version with rule.reverted" do
    rule = scenario.with_shipped_rules.find { |row| row.key == "acceptance_criteria" }
    owner_command("save_rule", save_body(rule, parameters: { "minimum_count" => 5 }).merge("id" => rule.id))

    outcome, events = owner_run("revert_rule", { "id" => rule.id })

    assert_completed(outcome)
    version = scenario.current_version(rule)
    assert_equal [ 3, { "minimum_count" => 1 } ], [ version.version, version.parameters ]
    assert_equal [ [ "rule.reverted", { "rule_version_id" => version.id, "version" => 3 } ] ],
      events.map { |event| [ event.type, event.payload ] }
  end

  test "a custom rule is invalid_state and writes nothing (RD-5)" do
    rule = scenario.rule

    outcome, events = owner_run("revert_rule", { "id" => rule.id })

    assert_refused("invalid_state", outcome)
    assert_empty events
    assert_equal 1, rule.reload.current_version
  end
end
