require_relative "contract_helper"

# hooks.json: every hook, what a failed gate does, its hashed inputs and its
# moment name. The PRD's Hooks table is compared with it by
# scripts/check_contract_tables.py.
class HooksTest < Minitest::Test
  include ContractTestHelpers

  # L464: the plain-language moments a custom rule may use, in that order.
  CUSTOM_MOMENTS = [
    "when a task is ready to start", "before an agent starts it", "before work is submitted",
    "when the review has passed", "before anything goes out"
  ].freeze

  def hooks = Leverage::Contract.hooks.fetch("hooks")
  def event_types = registry["event_types"].map { |entry| entry["type"] }

  def test_validates_against_its_meta_schema
    assert_empty meta_errors("hooks", Leverage::Contract.hooks)
  end

  def test_hooks_equal_the_registry_hooks
    assert_equal registry["hooks"], hooks.map { |entry| entry["hook"] }
  end

  def test_checkers_kinds_and_subjects_are_registered
    hooks.each do |entry|
      entry["checkers"].each { |checker| assert_includes Leverage::Contract.list("checkers"), checker, entry["hook"] }
      entry["rule_kinds"].each { |kind| assert_includes Leverage::Contract.list("rule_kinds"), kind, entry["hook"] }
      subject = entry["subject_kind"]
      assert(subject.nil? || Leverage::Contract.list("check_subject_kinds").include?(subject), entry["hook"])
    end
  end

  def test_a_failed_gate_effect_exactly_where_gates_run
    effects = Leverage::Contract.hooks["failed_gate_effects"].map { |entry| entry["effect"] }
    assert_empty duplicates(effects)
    hooks.each do |entry|
      if entry["rule_kinds"].include?("gate")
        assert_includes effects, entry["failed_gate"], entry["hook"]
      else
        assert_nil entry["failed_gate"], entry["hook"]
      end
    end
  end

  def test_policy_hooks_have_registered_effects_and_a_row_rule
    policy_hooks = hooks.select { |entry| entry["rule_kinds"].include?("policy") }.map { |entry| entry["hook"] }
    assert_equal registry["policy_effects"].keys.sort, policy_hooks.sort
    hooks.each do |entry|
      assert_equal entry["rule_kinds"].include?("policy"), !entry["policy_row"].nil?, entry["hook"]
    end
  end

  def test_custom_rule_hooks_and_their_moments
    custom = hooks.select { |entry| entry["custom_allowed"] }
    assert_equal registry["custom_rule_hooks"], custom.map { |entry| entry["hook"] }
    assert_equal CUSTOM_MOMENTS, custom.map { |entry| entry["moment_name"] }
    custom.each do |entry|
      assert_includes entry["checkers"], "model", entry["hook"]
      assert_includes entry["rule_kinds"], "gate", entry["hook"]
    end
  end

  def test_moment_names_are_unique_and_present
    names = hooks.map { |entry| entry["moment_name"] }
    names.each { |name| refute_empty name.strip }
    assert_empty duplicates(names)
  end

  def test_also_event_type_flag_is_right_both_ways
    hooks.each do |entry|
      assert_equal event_types.include?(entry["hook"]), entry["also_event_type"], entry["hook"]
    end
  end

  def test_hashed_inputs_are_named_once_in_snake_case
    hooks.each do |entry|
      refute_empty entry["hashed_inputs"], entry["hook"]
      assert_empty duplicates(entry["hashed_inputs"]), entry["hook"]
      entry["hashed_inputs"].each { |name| assert_match SNAKE_CASE, name, entry["hook"] }
    end
  end
end
