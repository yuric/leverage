require_relative "contract_helper"

# shipped_rules.json: the seven rules a new workspace is created with (PRD,
# Shipped rules), with the version-1 fields the PRD leaves open (plan RC-7).
class ShippedRulesTest < Minitest::Test
  include ContractTestHelpers

  def rules = Leverage::Contract.shipped_rules.fetch("rules")
  def hook(name) = Leverage::Contract.hooks.fetch("hooks").find { |entry| entry["hook"] == name }
  def rule(key) = rules.find { |entry| entry["key"] == key }

  def test_validates_against_its_meta_schema
    assert_empty meta_errors("shipped_rules", Leverage::Contract.shipped_rules)
  end

  def test_the_seven_rules_have_unique_snake_case_keys
    # The PRD's Shipped rules table has seven rows.
    assert_equal 7, rules.size
    keys = rules.map { |entry| entry["key"] }
    assert_empty duplicates(keys)
    keys.each { |key| assert_match SNAKE_CASE, key }
  end

  def test_values_come_from_the_registry_and_the_hook_allows_them
    rules.each do |entry|
      key = entry["key"]
      assert_includes registry["hooks"], entry["hook"], key
      assert_includes Leverage::Contract.list("rule_kinds"), entry["kind"], key
      assert_includes Leverage::Contract.list("checkers"), entry["checker"], key
      assert_includes Leverage::Contract.list("scope_kinds"), entry["scope"]["kind"], key
      assert_includes Leverage::Contract.list("rule_origins"), entry["origin"], key
      assert_includes hook(entry["hook"])["rule_kinds"], entry["kind"], key
      assert_includes hook(entry["hook"])["checkers"], entry["checker"], key
    end
  end

  def test_gates_have_on_fail_and_route_and_policies_have_neither
    rules.each do |entry|
      if entry["kind"] == "gate"
        assert_includes Leverage::Contract.list("on_fail"), entry["on_fail"], entry["key"]
        assert_includes Leverage::Contract.list("routes"), entry["route"], entry["key"]
      else
        assert_nil entry["on_fail"], entry["key"]
        assert_nil entry["route"], entry["key"]
      end
    end
  end

  # Both model-checked rules ship with instructions (RV-2 and AP-23).
  def test_app_rules_name_a_function_and_model_rules_an_instruction
    rules.each do |entry|
      if entry["checker"] == "app"
        assert_match SNAKE_CASE, entry["checker_function"], entry["key"]
        assert_nil entry["instruction"], entry["key"]
        assert_nil entry["checker_role"], entry["key"]
      else
        assert_nil entry["checker_function"], entry["key"]
        assert_empty entry["parameters"], entry["key"]
        instruction = entry["instruction"]
        assert_kind_of String, instruction, entry["key"]
        refute_empty instruction.strip, entry["key"]
        assert_equal "orchestrator", entry["checker_role"], entry["key"]
      end
    end
  end

  def test_parameters_are_typed_with_their_prd_defaults
    assert_equal({ "type" => "integer", "minimum" => 0, "default" => 1 },
      rule("acceptance_criteria")["parameters"]["minimum_count"])
    assert_equal({ "type" => "integer", "minimum" => 1, "default" => 2 },
      rule("escalate_after_failed_reviews")["parameters"]["threshold"])
  end

  def test_version_one_ships_on_with_workspace_timeouts
    rules.each do |entry|
      assert entry["enabled"], entry["key"]
      assert_equal "shipped", entry["origin"], entry["key"]
      assert_equal 1, entry["version"], entry["key"]
      assert_nil entry["queue_timeout_seconds"], entry["key"]
      assert_nil entry["run_timeout_seconds"], entry["key"]
      assert_equal({ "kind" => "all_tasks", "values" => [] }, entry["scope"], entry["key"])
    end
  end

  def test_every_policy_hook_with_a_shipped_rule_has_its_effects
    rules.select { |entry| entry["kind"] == "policy" }.each do |entry|
      assert registry["policy_effects"].key?(entry["hook"]), entry["key"]
    end
  end
end
