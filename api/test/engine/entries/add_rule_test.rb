require "test_helper"
require_relative "rule_support"
require_relative "../../support/trace_runner"

# Entries::AddRule (PRD L342, L423; milestone 4 plan RD-4, RD-21 to RD-24):
# the owner adds a custom rule, a model-checked gate that blocks, at one of
# the five moments a task can reach. Scope values must fit their kind
# and any projects they name must belong to the workspace.
class AddRuleTest < ActiveSupport::TestCase
  include RuleSupport

  setup { use_scenario }

  test "it writes rule.created for the new rule, by the owner, with the command's key (trace 17, command 1)" do
    outcome, events = owner_run("add_rule", add_body)

    assert_completed(outcome)
    assert_nil outcome.result
    rule = Rule.find_by!(workspace_id: scenario.workspace_id)
    version = scenario.current_version(rule)
    assert_equal [ "rule.created" ], events.map(&:type)
    event = events.sole
    assert_equal [ "owner", scenario.owner.id, "rule", rule.id, nil, nil, nil ],
      [ event.actor_kind, event.actor_id, event.subject_kind, event.subject_id, event.task_id, event.round, event.cause_id ]
    assert_equal({ "rule_version_id" => version.id, "version" => 1, "enabled" => true }, event.payload)
    assert_equal [ "task.before_submit", "builder", "block", "model" ], [ version.hook, version.route, version.on_fail, version.checker ]
  end

  test "each of the five custom rule moments is offered" do
    hooks = Leverage::Contract.registry.fetch("custom_rule_hooks")
    hooks.each do |hook|
      assert_completed(owner_command("add_rule", add_body(hook: hook)))
    end
    versions = RuleVersion.where(workspace_id: scenario.workspace_id)
    assert_equal hooks.sort, versions.pluck(:hook).sort
    assert_equal "owner", versions.find_by!(hook: "action.requested").route
  end

  test "named projects and action kinds are stored on the rule version" do
    project = scenario.project
    [
      [ { "kind" => "named_projects", "project_ids" => [ project.id ], "action_kinds" => nil }, [ project.id ] ],
      [ { "kind" => "action_kinds", "project_ids" => nil, "action_kinds" => %w[publish send] }, %w[publish send] ]
    ].each do |scope, values|
      assert_completed(owner_command("add_rule", add_body(hook: "action.requested", scope: scope)))
      version = RuleVersion.find_by!(workspace_id: scenario.workspace_id, scope_kind: scope.fetch("kind"))
      assert_equal values, version.scope_values
    end
  end

  test "foreign projects and invalid scope values are 422 invalid and write nothing" do
    project = scenario.project
    foreign = Scenario.new.project
    bodies = [
      add_body(scope: { "kind" => "named_projects", "project_ids" => [ project.id, foreign.id ], "action_kinds" => nil }),
      add_body(scope: { "kind" => "action_kinds", "project_ids" => nil, "action_kinds" => [ "made_up" ] }),
      add_body(scope: { "kind" => "all_tasks", "project_ids" => [ project.id ], "action_kinds" => nil })
    ]
    counts = [ Rule.count, Event.count, Command.count ]

    bodies.each { |body| assert_raises(T::Invalid) { owner_command("add_rule", body) } }
    assert_equal counts, [ Rule.count, Event.count, Command.count ]
  end

  test "a repeat of its key answers the stored outcome and adds no second rule" do
    key = new_key
    owner_command("add_rule", add_body, key: key)

    assert_completed(owner_command("add_rule", add_body, key: key))
    assert_equal 1, Rule.where(workspace_id: scenario.workspace_id).count
  end

  # One trace per test: a trace's setup ids are TraceBinder's, the same in
  # every trace for the same symbol.
  %w[17-submit-rule-rerun-and-override 18-claim-gate-done-gate-and-ends].each do |name|
    test "trace #{name[0, 2]}'s first command adds its rule as the trace writes it" do
      runner = TraceRunner.new(name).run(1)
      assert_empty runner.failures
    end
  end
end
