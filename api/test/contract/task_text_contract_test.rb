require_relative "contract_helper"
require "digest"

# The owner's app round 1 (contract decisions UI-1 to UI-8): a task has no
# goal. Its goal is folded into its details, the shapes that carried it
# carry the title and the details instead, the specific-details rule judges
# the title, the details and the criteria, and Add task can fill "Where the
# work is" from the project. A project keeps its own goal (UI-7). Every
# name is read from the contract files.
class TaskTextContractTest < Minitest::Test
  include ContractTestHelpers

  # The components that are a task's text, or hold it. A project's
  # components (Project, CreateProjectRequest) keep their goal.
  TASK_SHAPES = %w[TaskSummary BriefingContract CheckContract DraftMaterial CompleteContractRequest AddTaskRequest
                   ActionJobContract].freeze
  PROJECT_SHAPES = %w[Project CreateProjectRequest].freeze

  # The details' old limit, the goal's, and the blank line between them
  # (UI-2): a folded task can be saved again unchanged.
  DETAILS_LIMIT = 20_000 + 4_000 + 2

  # The SHA-256 of the specific-details instruction every recorded eval
  # run used (evals/specific-details/runs.json): the default it replaces.
  SUPERSEDED_SHA256 = "b49ffaec2ea3f88fbe0ec629170bec42911c213e3af0919e8365373b7d145906".freeze

  # The commands whose body is a task's text.
  TASK_COMMANDS = %w[add_task complete_contract edit_contract submit_job_result].freeze

  def openapi = Leverage::Contract.openapi
  def schemas = openapi.dig("components", "schemas")
  def schema(name) = schemas.fetch(name)
  def shipped(key) = Leverage::Contract.shipped_rules.fetch("rules").find { |rule| rule["key"] == key }
  def fold_file = File.join(CONTRACT_ROOT, "goal_fold.json")
  def decisions = File.read(File.join(CONTRACT_ROOT, "decisions.md"))
  def rows = Leverage::Contract.state_machine.fetch("groups").flat_map { |group| group.fetch("rows") }

  # The fold the migration and the eval cases apply (UI-1), written once
  # more here so that goal_fold.json's examples are checked against it.
  def fold(title, goal, details)
    trimmed = goal.to_s.gsub(/\A[ \t\r\n]+|[ \t\r\n]+\z/, "")
    return details if trimmed.empty? || trimmed == title.to_s.gsub(/\A[ \t\r\n]+|[ \t\r\n]+\z/, "")
    return trimmed if details.nil? || details.gsub(/\A[ \t\r\n]+|[ \t\r\n]+\z/, "").empty?

    "#{trimmed}\n\n#{details}"
  end

  # assert_equal, also when the text expected is null.
  def assert_same_text(expected, actual, message)
    expected.nil? ? assert_nil(actual, message) : assert_equal(expected, actual, message)
  end

  # Every object under `value` that has a "goal" key, with its path, except
  # a schema's properties list.
  def goals_in(value, path = [], found = [])
    case value
    when Hash
      found << [ path.join("/"), value ] if value.key?("goal") && path.last != "properties"
      value.each { |key, child| goals_in(child, path + [ key ], found) }
    when Array
      value.each_with_index { |child, index| goals_in(child, path + [ index ], found) }
    end
    found
  end

  # UI-1: no task shape has a goal, as a field or as a required name.
  def test_no_task_shape_carries_a_goal
    TASK_SHAPES.each do |name|
      refute schema(name).fetch("properties").key?("goal"), "#{name} still has a goal"
      refute_includes schema(name).fetch("required", []), "goal", name
    end
  end

  # UI-7: a project's goal is not a task's goal, and stays.
  def test_a_project_keeps_its_goal
    PROJECT_SHAPES.each { |name| assert schema(name).fetch("properties").key?("goal"), name }
  end

  # UI-1: Add task needs only a title.
  def test_add_task_requires_only_a_title
    assert_equal %w[title], schema("AddTaskRequest").fetch("required")
  end

  # UI-2: the details take a folded goal.
  def test_the_details_limit_takes_a_folded_goal
    %w[AddTaskRequest CompleteContractRequest].each do |name|
      assert_equal DETAILS_LIMIT, schema(name).dig("properties", "details", "maxLength"), name
    end
  end

  # UI-3: a builder's briefing names the task by its title.
  def test_the_briefing_contract_carries_the_title
    briefing = schema("BriefingContract")
    assert_equal({ "type" => "string" }, briefing.dig("properties", "title"))
    assert_includes briefing.fetch("required"), "title"
  end

  # UI-1: no example in the interface schema gives a task a goal. A
  # project, named and with no title, keeps its goal (UI-7).
  def test_no_interface_example_gives_a_task_a_goal
    found = goals_in(openapi).reject { |_, object| object.key?("name") && !object.key?("title") }
    assert_empty found.map(&:first)
    refute_empty goals_in(openapi), "a project example keeps its goal"
  end

  # UI-1: no golden trace sends a task's goal; a project's goal is sent.
  def test_no_trace_sends_a_task_goal
    sent = Hash.new(0)
    Dir.glob("traces/*.json", base: CONTRACT_ROOT).sort.each do |relative|
      Leverage::Contract.load(relative).fetch("commands").each do |command|
        goals_in(command["body"]).each { sent[command["command"]] += 1 }
      end
    end
    assert_empty sent.keys & TASK_COMMANDS
    assert_operator sent["create_project"], :>, 0
  end

  # UI-4: the specific-details rule judges the title, so the title is hashed.
  def test_task_before_ready_hashes_the_title_and_the_details
    hook = Leverage::Contract.hooks.fetch("hooks").find { |entry| entry["hook"] == "task.before_ready" }
    assert_equal %w[title details criteria actions], hook.fetch("hashed_inputs")
    assert_equal "The contract: title, details, criteria, outward actions", hook.fetch("prd_hashed_inputs")
  end

  # UI-5: the instruction judges the title, the details and the criteria,
  # and names no goal.
  def test_the_specific_details_instruction_names_no_goal
    instruction = shipped("specific_details").fetch("instruction")
    refute_match(/\bgoal\b/i, instruction)
    assert_includes instruction, "from its title, its details and its acceptance criteria alone"
    Leverage::Contract.shipped_rules.fetch("rules").each do |rule|
      refute_match(/\bgoal\b/i, rule["instruction"].to_s, rule["key"])
    end
  end

  # UI-5: the default it replaces is kept, so that a workspace still on it
  # is moved to the new one.
  def test_the_replaced_default_is_kept
    superseded = shipped("specific_details")["superseded_instructions"]
    assert_kind_of Array, superseded, "no superseded_instructions"
    assert_equal [ SUPERSEDED_SHA256 ], superseded.map { |text| Digest::SHA256.hexdigest(text) }
    Leverage::Contract.shipped_rules.fetch("rules").each do |rule|
      assert_empty Array(rule["superseded_instructions"]) & [ rule["instruction"] ], rule["key"]
    end
  end

  # UI-5: Write the shipped rules moves a rule still on an earlier default
  # to the new one.
  def test_write_the_shipped_rules_may_revert_an_earlier_default
    row = rows.find { |entry| entry["command"] == "install_shipped_rules" }
    assert_includes row.fetch("conditional_events").map { |event| event["event"] }, "rule.reverted"
    assert_match(/superseded_instructions/, row.fetch("note"))
  end

  # UI-1: goal_fold.json's examples are the fold, and cover each branch.
  def test_the_fold_examples_are_the_fold
    assert File.exist?(fold_file), "no goal_fold.json"
    data = Leverage::Contract.load("goal_fold.json")
    assert_equal "\n\n", data.fetch("separator")
    assert_equal " \t\r\n", data.fetch("trimmed")
    examples = data.fetch("examples")
    examples.each do |example|
      folded = fold(example.fetch("title"), example.fetch("goal"), example.fetch("details"))
      assert_same_text example.fetch("details_after"), folded, example.fetch("name")
    end
    assert_operator examples.map { |example| example["name"] }.uniq.size, :>=, 7
  end

  def test_the_fold_file_has_a_meta_schema
    assert File.exist?(fold_file), "no goal_fold.json"
    assert File.exist?(File.join(CONTRACT_ROOT, "meta", "goal_fold.schema.json")), "no meta/goal_fold.schema.json"
    assert_empty meta_errors("goal_fold", Leverage::Contract.load("goal_fold.json"))
  end

  # UI-6: a project tells Add task where its work was last.
  def test_a_project_names_its_latest_work_reference
    project = schema("Project")
    assert_equal({ "type" => %w[string null] }, project.dig("properties", "latest_work_reference")&.except("description"))
    assert_includes project.fetch("required"), "latest_work_reference"
  end

  def test_the_decisions_are_written_down
    (1..8).each { |number| assert_match(/^- \*\*UI-#{number}\*\*/, decisions, "UI-#{number}") }
    assert_match(/DB-48/, decisions[/^- \*\*UI-1\*\*.*?(?=^- \*\*UI-2\*\*)/m].to_s)
  end
end
