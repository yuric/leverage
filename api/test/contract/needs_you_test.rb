require_relative "contract_helper"

# needs_you.json: every Needs you item, its choices and the facts it stores
# (plan DB-33). The PRD's Needs you choices table is compared with it by
# scripts/check_contract_tables.py.
class NeedsYouTest < Minitest::Test
  include ContractTestHelpers

  def items = Leverage::Contract.needs_you.fetch("items")
  def item(name) = items.find { |entry| entry["item"] == name }
  def operation(id) = registry["operations"].find { |op| op["operation_id"] == id }

  # The choices an item offers when the named conditions hold.
  def offered(name, conditions)
    item(name)["choices"].select { |choice| choice["when"].nil? || conditions.include?(choice["when"]) }
                         .map { |choice| choice["choice"] }
  end

  def test_validates_against_its_meta_schema
    assert_empty meta_errors("needs_you", Leverage::Contract.needs_you)
  end

  def test_items_equal_the_registry_items
    assert_equal registry["needs_you_items"], items.map { |entry| entry["item"] }
  end

  def test_about_and_hold_reason_are_registered_and_match_the_registry
    holds = registry["hold_reasons"]
    items.each do |entry|
      assert_includes Leverage::Contract.list("inbox_about_kinds"), entry["about"], entry["item"]
      next if entry["hold_reason"].nil?

      hold = holds.find { |row| row["reason"] == entry["hold_reason"] }
      refute_nil hold, entry["item"]
      assert_equal entry["item"], hold["needs_you_item"], entry["item"]
    end
    holds.each do |hold|
      next if hold["needs_you_item"].nil?

      assert_equal hold["reason"], item(hold["needs_you_item"])["hold_reason"], hold["reason"]
    end
  end

  def test_choices_are_registered_and_name_an_owner_call
    items.each do |entry|
      choices = entry["choices"].map { |choice| choice["choice"] }
      assert_empty duplicates(choices), entry["item"]
      entry["choices"].each do |choice|
        assert_includes Leverage::Contract.list("inbox_choices"), choice["choice"], entry["item"]
        op = operation(choice["operation_id"])
        refute_nil op, "#{entry["item"]}: #{choice["operation_id"]}"
        assert_equal "owner", op["tag"], choice["operation_id"]
        assert(choice["when"].nil? || registry["guards"].include?(choice["when"]), "#{entry["item"]}: #{choice["when"]}")
      end
      refute_nil entry["closes"], "#{entry["item"]} offers no choice and says nothing of how it closes" if choices.empty?
    end
  end

  def test_a_stopped_action_offers_override_only_when_a_check_stopped_it
    refute_includes offered("stopped_action", %w[no_action_started]), "override_once"
    assert_includes offered("stopped_action", %w[no_action_started stopped_by_check]), "override_once"
    refute_includes offered("stopped_action", %w[stopped_by_check]), "return_for_rework"
  end

  def test_facts_are_closed_object_schemas
    items.each do |entry|
      facts = entry["facts"]
      assert JSONSchemer.valid_schema?(facts.merge("$schema" => "https://json-schema.org/draft/2020-12/schema")), entry["item"]
      assert_equal "object", facts["type"], entry["item"]
      assert_equal false, facts["additionalProperties"], entry["item"]
      assert_equal facts["properties"].keys.sort, facts["required"].sort, entry["item"]
      facts["properties"].each do |name, schema|
        next unless Array(schema["type"]).include?("string")

        assert(schema.key?("enum") || schema["format"] == "uuid", "#{entry["item"]}.#{name} is free text")
      end
    end
  end

  def test_an_unconfirmed_action_stores_what_the_owner_is_told
    assert_equal %w[action_ids approved_by_id approved_by_kind builder_announced_start],
      item("unconfirmed_action")["facts"]["properties"].keys.sort
  end
end
