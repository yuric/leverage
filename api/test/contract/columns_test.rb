require_relative "contract_helper"
require_relative "../db/expected_schema"

# Field names in the contract are the Data model's column names (IF-1,
# api/contract/README.md "Names"), so one fact is never spelled two ways.
# The columns come from test/db/expected_schema.rb, which schema_test.rb
# holds equal to the database the migrations build. Plain data, no database.
class ColumnsTest < Minitest::Test
  include ContractTestHelpers

  # openapi.json components that are one table's rows or one table's
  # settings, beyond those named after their table.
  COMPONENT_TABLES = {
    "TaskSummary" => %w[tasks],
    "Criterion" => %w[criteria],
    "WorkspaceSettings" => %w[workspaces],
    "ChangeWorkspaceSettingsRequest" => %w[workspaces],
    "SaveRuleRequest" => %w[rule_versions],
    "AddRuleRequest" => %w[rule_versions]
  }.freeze

  # Fields that are not a column, each with the column or fact it stands
  # for. Every other field of a mapped component must be a column.
  NOT_COLUMNS = {
    # The two columns scope_kind and scope_values, as one RuleScope object.
    "RuleVersion" => %w[scope],
    "SaveRuleRequest" => %w[scope],
    "AddRuleRequest" => %w[scope],
    # The criterion's evidence rows, in the briefing's contract part (IF-25).
    "Criterion" => %w[evidence],
    # The seq of the item's inbox.opened event, so that after_seq on the
    # Needs you list has a meaning (IF-18). Detail comes from the access
    # hold or the stopped action's approval job.
    "InboxItem" => %w[opened_seq detail],
    # Text made from the seat's role, the connection, the contract and a
    # template (GA-12, GA-14). A read with no table behind it.
    "JoinInstructions" => %w[text role connection],
    # The short prompt with the token in it, and the connection it names
    # (GA-13). Nothing of it is stored.
    "LandingPromptIssued" => %w[text connection],
    # Derived from the action's approval event and the rule check that stopped it.
    "Action" => %w[approved_at stopped_by_rule_check_id],
    # The project pause's actor, the count of unfinished tasks, the current
    # brief, and whether it is the workspace's Imaginarium project (DB-53).
    "Project" => %w[paused_by open_tasks brief imaginarium],
    # True when the question's outcome is overturned.
    "Question" => %w[overturned],
    # A step's length, closed_at (or the read's as_of for the open one)
    # less opened_at (milestone 4 plan section 2.3).
    "TaskStep" => %w[seconds]
  }.freeze

  # A trace's rules rows carry the rule's columns, its current version's
  # columns and current_version_id, the $rule_version symbol check payloads
  # name (meta/trace.schema.json, setup.rules).
  TRACE_RULE_EXTRAS = %w[current_version_id].freeze

  def columns(table)
    ExpectedSchema::TABLES.fetch(table).fetch(:columns).keys
  end

  def schemas = Leverage::Contract.openapi.fetch("components").fetch("schemas")

  def table_for(component)
    return COMPONENT_TABLES[component] if COMPONENT_TABLES.key?(component)

    snake = component.gsub(/(?<!\A)([A-Z])/, '_\1').downcase
    candidates = [ "#{snake}s", "#{snake}es", snake.sub(/y\z/, "ies"), snake ]
    table = candidates.find { |name| ExpectedSchema::TABLES.key?(name) }
    table && [ table ]
  end

  def test_the_mapped_components_cover_the_settings_and_rule_shapes
    %w[WorkspaceSettings ChangeWorkspaceSettingsRequest RuleVersion SaveRuleRequest TaskSummary].each do |component|
      assert table_for(component), "#{component} is tied to no table"
    end
  end

  def test_component_fields_are_column_names
    schemas.each do |component, schema|
      tables = table_for(component)
      next unless tables && schema["properties"]

      allowed = tables.flat_map { |table| columns(table) } + NOT_COLUMNS.fetch(component, [])
      assert_empty schema["properties"].keys - allowed, "#{component} (#{tables.join(", ")}) has fields that are not columns"
    end
  end

  def test_every_field_that_is_not_a_column_is_still_in_its_component
    NOT_COLUMNS.each do |component, names|
      assert_empty names - schemas.fetch(component).fetch("properties").keys, component
    end
  end

  def test_shipped_rule_fields_are_rule_and_rule_version_columns
    allowed = columns("rules") + columns("rule_versions") + %w[scope]
    Leverage::Contract.shipped_rules.fetch("rules").each do |rule|
      fields = rule.keys.reject { |key| key.start_with?("prd_") }
      assert_empty fields - allowed, rule["key"]
    end
  end

  def test_trace_settings_are_workspace_columns
    traces.each do |name, trace|
      assert_empty trace.dig("setup", "settings").keys - columns("workspaces"), name
    end
  end

  def test_trace_setup_rows_are_columns_of_their_tables
    traces.each do |name, trace|
      %w[users helpers credentials seats projects].each do |table|
        trace.dig("setup", table).each do |row|
          assert_empty row.keys - columns(table), "#{name}: setup.#{table}"
        end
      end
      allowed = columns("rules") + columns("rule_versions") + TRACE_RULE_EXTRAS
      trace.dig("setup", "rules").each do |row|
        assert_empty row.keys - allowed, "#{name}: setup.rules #{row["id"]}"
      end
    end
  end

  def test_trace_steps_and_events_use_their_column_names
    defs = Leverage::Contract.meta_schema("trace").fetch("$defs")
    %w[step_opened step_closed].each do |name|
      assert_empty defs.fetch(name).fetch("properties").keys - columns("task_steps"), name
    end
    # `ref` names the event itself: it binds to events.id.
    assert_empty defs.fetch("event").fetch("properties").keys - columns("events") - %w[ref], "event"
  end

  def traces
    Dir.glob(File.join(CONTRACT_ROOT, "traces", "*.json")).sort.to_h do |path|
      [ File.basename(path, ".json"), JSON.parse(File.read(path)) ]
    end
  end
end
