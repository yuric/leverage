require "test_helper"

# Leverage::Rules::Shipped (milestone 4 plan §2.1, WP1): the seven shipped
# rules as the version fields a workspace's records are written with, read
# from shipped_rules.json, and what Revert to default writes (L342, L434).
# The class is not ShippedRulesTest, which is the contract's test of the
# file itself (test/contract, loaded by bin/rails test too; plan RT-6).
class ShippedRecordsTest < ActiveSupport::TestCase
  Shipped = Leverage::Rules::Shipped

  def json_rules = Leverage::Contract.shipped_rules.fetch("rules")

  test "all is the seven rules of shipped_rules.json, in its order" do
    assert_equal 7, Shipped.all.size
    assert_equal json_rules.map { |rule| rule.fetch("key") }, Shipped.all.map(&:key)
    assert Shipped.all.frozen?
  end

  test "each record has the file's fields" do
    json_rules.each do |rule|
      record = Shipped.find(rule.fetch("key"))
      expected = rule.slice(*%w[key name hook kind checker checker_function checker_role on_fail route queue_timeout_seconds
                                 run_timeout_seconds origin enabled version])
      assert_equal expected, expected.keys.to_h { |field| [ field, record.public_send(field) ] }, rule.fetch("key")
      assert_equal [ rule.dig("scope", "kind"), rule.dig("scope", "values") ], [ record.scope_kind, record.scope_values ]
    end
  end

  test "a version's parameters are the defaults of the file's parameter schemas" do
    assert_equal({ "minimum_count" => 1 }, Shipped.find("acceptance_criteria").parameters)
    assert_equal({ "threshold" => 2 }, Shipped.find("escalate_after_failed_reviews").parameters)
    assert_equal({}, Shipped.find("different_provider_review").parameters)
    assert_equal({}, Shipped.find("specific_details").parameters)
    assert_equal({ "minimum_count" => { "type" => "integer", "minimum" => 0, "default" => 1 } },
      Shipped.find("acceptance_criteria").parameter_schema)
  end

  test "the two shipped model rules carry their instructions" do
    %w[specific_details orchestrator_approves_actions].each do |key|
      text = json_rules.find { |rule| rule.fetch("key") == key }.fetch("instruction")
      assert_kind_of String, text
      assert text == Shipped.find(key).instruction
    end
    assert_nil Shipped.find("acceptance_criteria").instruction
  end

  test "find refuses a key that is not shipped" do
    assert_raises(KeyError) { Shipped.find("custom_made_up") }
  end

  test "version_fields are rule_versions columns, and a version row can be written from them" do
    record = Shipped.find("acceptance_criteria")
    fields = record.version_fields
    assert_empty fields.keys.map(&:to_s) - RuleVersion.column_names
    assert_equal "shipped", fields.fetch(:origin)

    scenario = Scenario.new
    rule = Rule.create!(workspace_id: scenario.workspace_id, key: record.key, enabled: true, current_version: 1)
    version = RuleVersion.create!(workspace_id: scenario.workspace_id, rule_id: rule.id, version: 1, author_kind: "app",
      **fields)
    assert_equal [ "acceptance_criteria", "task.before_ready", { "minimum_count" => 1 }, "all_tasks", [] ],
      [ version.key, version.hook, version.parameters, version.scope_kind, version.scope_values ]
  end
end
