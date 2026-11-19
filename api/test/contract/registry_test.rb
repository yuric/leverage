require_relative "contract_helper"

# registry.json: its shape and its internal consistency. Whether its four
# PRD-compared lists equal the PRD is proven by scripts/check_registry.py
# (the D17 check), so nothing here counts entries or copies a PRD table.
class RegistryTest < Minitest::Test
  include ContractTestHelpers

  NAME_LISTS = %w[step_kinds needs_you_items hooks custom_rule_hooks commands guards due_time_sources].freeze

  def test_validates_against_its_meta_schema
    assert_empty meta_errors("registry", registry)
  end

  def test_no_list_has_duplicates
    lists = {
      "event_types" => registry["event_types"].map { |entry| entry["type"] },
      "hold_reasons" => registry["hold_reasons"].map { |entry| entry["reason"] },
      "refusals" => registry["refusals"].map { |entry| entry["code"] },
      "check_results" => registry["check_results"],
      "release_reasons" => registry["release_reasons"].map { |entry| entry["reason"] },
      "next_kinds" => registry["next_kinds"],
      "operations" => registry["operations"].map { |entry| entry["operation_id"] },
      "operation routes" => registry["operations"].map { |entry| "#{entry["method"]} #{entry["path"]}" },
      "job_kinds" => registry["job_kinds"].map { |entry| entry["kind"] },
      "credential_providers" => registry["credential_providers"].map { |entry| entry["provider"] }
    }
    NAME_LISTS.each { |name| lists[name] = registry[name] }
    registry["lists"].each { |name, values| lists["lists.#{name}"] = values }
    lists.each { |name, values| assert_empty duplicates(values), "#{name} has duplicates" }
  end

  def test_refusal_precedence_is_contiguous_from_one
    ranked = registry["refusals"].map { |entry| entry["precedence"] }.compact
    assert_equal (1..ranked.size).to_a, ranked.sort
    assert_equal ranked.sort, ranked, "refusals are listed in precedence order"
  end

  def test_not_eligible_is_claims_only_with_no_precedence
    not_eligible = registry["refusals"].find { |entry| entry["code"] == "not_eligible" }
    refute_nil not_eligible
    assert not_eligible["claims_only"]
    assert_nil not_eligible["precedence"]
    registry["refusals"].each do |entry|
      assert_equal entry["claims_only"], entry["precedence"].nil?,
        "#{entry["code"]}: only a claims-only refusal has no precedence"
      refute entry["claims_only"] && entry["owner_only"], "#{entry["code"]} is both claims-only and owner-only"
    end
  end

  def test_hold_reasons_name_registered_steps_and_items
    registry["hold_reasons"].each do |entry|
      assert_includes registry["step_kinds"], entry["step"], entry["reason"]
      next if entry["needs_you_item"].nil?

      assert_includes registry["needs_you_items"], entry["needs_you_item"], entry["reason"]
    end
  end

  def test_event_subject_kinds_are_registered
    kinds = registry["lists"]["event_subject_kinds"]
    registry["event_types"].each do |entry|
      refute_empty entry["subject_kinds"], entry["type"]
      entry["subject_kinds"].each do |kind|
        assert(kind.nil? || kinds.include?(kind), "#{entry["type"]}: subject kind #{kind.inspect}")
      end
    end
  end

  def test_event_types_have_contiguous_schema_versions
    registry["event_types"].each do |entry|
      versions = entry["schema_versions"]
      assert_equal (1..versions.size).to_a, versions, entry["type"]
    end
  end

  def test_custom_rule_hooks_are_hooks
    registry["custom_rule_hooks"].each { |hook| assert_includes registry["hooks"], hook }
  end

  def test_policy_effects_are_keyed_by_hook
    registry["policy_effects"].each do |hook, effects|
      assert_includes registry["hooks"], hook
      refute_empty effects, hook
      effects.each { |effect| assert_match SNAKE_CASE, effect, hook }
    end
  end

  def test_operations_name_registered_commands_callers_and_tags
    commands = registry["commands"]
    registry["operations"].each do |operation|
      id = operation["operation_id"]
      refute_empty operation["commands"], id
      operation["commands"].each do |command|
        assert(command == "read" || commands.include?(command), "#{id}: unknown command #{command}")
      end
      reads = operation["commands"] == [ "read" ]
      assert_equal operation["method"] == "GET", reads, "#{id}: GET operations read, others change something"
      assert_includes registry["lists"]["operation_callers"], operation["caller"], id
      assert_includes registry["lists"]["operation_tags"], operation["tag"], id
    end
  end

  def test_every_operation_tag_and_caller_is_used
    used_tags = registry["operations"].map { |operation| operation["tag"] }.uniq
    used_callers = registry["operations"].map { |operation| operation["caller"] }.uniq
    assert_equal registry["lists"]["operation_tags"].sort, used_tags.sort
    assert_equal registry["lists"]["operation_callers"].sort, used_callers.sort
  end

  def test_job_kind_components_are_unique
    names = registry["job_kinds"].flat_map { |entry| [ entry["input_component"], entry["result_component"] ] }
    assert_empty duplicates(names)
  end

  def test_next_kinds_are_in_precedence_order
    assert_equal %w[command briefing_changed resume answer action rework review job task none], registry["next_kinds"]
  end

  def test_release_reasons_are_chosen_by_a_seat_or_the_app
    registry["release_reasons"].each do |entry|
      assert_includes %w[seat app], entry["chosen_by"], entry["reason"]
      assert_includes registry["lists"]["actor_kinds"], entry["chosen_by"]
    end
  end

  def test_credential_providers_use_registered_kinds_and_groups
    registry["credential_providers"].each do |entry|
      assert_includes registry["lists"]["credential_kinds"], entry["kind"], entry["provider"]
      assert_includes registry["lists"]["provider_groups"], entry["provider_group"], entry["provider"]
    end
    used = registry["credential_providers"].map { |entry| entry["provider_group"] }.uniq
    assert_equal registry["lists"]["provider_groups"].sort, used.sort
  end

  def test_names_are_snake_case_and_types_are_dotted
    snake = registry["check_results"] + registry["next_kinds"] + registry["step_kinds"] +
      registry["needs_you_items"] + registry["commands"] + registry["guards"] +
      registry["hold_reasons"].map { |entry| entry["reason"] } +
      registry["refusals"].map { |entry| entry["code"] } +
      registry["release_reasons"].map { |entry| entry["reason"] } +
      registry["operations"].map { |entry| entry["operation_id"] } +
      registry["job_kinds"].map { |entry| entry["kind"] } +
      registry["credential_providers"].flat_map { |entry| [ entry["provider"], entry["provider_group"] ] } +
      registry["lists"].keys + registry["lists"].values.flatten
    snake.each { |value| assert_match SNAKE_CASE, value }

    dotted = registry["event_types"].map { |entry| entry["type"] } + registry["hooks"] +
      registry["due_time_sources"]
    dotted.each { |value| assert_match DOTTED, value }
  end
end
