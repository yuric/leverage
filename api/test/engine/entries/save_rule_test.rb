require "test_helper"
require_relative "rule_support"
require_relative "../../support/trace_runner"

# Entries::SaveRule (PRD L342, L911; milestone 4 plan RD-5, RD-6, RD-24):
# the owner saves a rule's fields as its next version; a check made
# earlier keeps the version it ran against. A rule of another workspace is
# 404, a removed rule invalid_state, fields that do not fit 422 invalid.
class SaveRuleTest < ActiveSupport::TestCase
  include RuleSupport

  setup do
    use_scenario
    @rule = scenario.rule(hook: "task.before_submit")
  end

  test "it writes rule.changed for version 2 and the earlier check keeps version 1 (trace 17, command 16; L911)" do
    task = scenario.task(state: "working", builder: scenario.seat(role: "builder", credential: scenario.credential))
    check = scenario.rule_check(task, rule: @rule, result: "failed", reason: "Made-up reason.")
    first = scenario.current_version(@rule)

    outcome, events = owner_run("save_rule", save_body(@rule, instruction: "Made-up stricter wording.").merge("id" => @rule.id))

    assert_completed(outcome)
    version = scenario.current_version(@rule)
    assert_equal [ 2, "Made-up stricter wording." ], [ version.version, version.instruction ]
    assert_equal [ [ "rule.changed", { "rule_version_id" => version.id, "version" => 2 }, "owner", @rule.id ] ],
      events.map { |event| [ event.type, event.payload, event.actor_kind, event.subject_id ] }
    assert_equal first.id, check.reload.rule_version_id
  end

  test "each of the three routes is accepted and stored (RD-24)" do
    %w[builder orchestrator owner].each do |route|
      assert_completed(owner_command("save_rule", save_body(@rule, route: route).merge("id" => @rule.id)))
      assert_equal route, scenario.current_version(@rule).route
    end
  end

  test "a field that does not fit the rule is 422 invalid and writes nothing (RD-6)" do
    counts = [ RuleVersion.count, Event.count, Command.count ]

    assert_raises(T::Invalid) { owner_command("save_rule", save_body(@rule, on_fail: nil).merge("id" => @rule.id)) }
    assert_raises(T::Invalid) { owner_command("save_rule", save_body(@rule, instruction: nil).merge("id" => @rule.id)) }
    assert_equal counts, [ RuleVersion.count, Event.count, Command.count ]
  end

  test "a removed rule is invalid_state (RD-5)" do
    @rule.update!(removed_at: scenario.database_now)

    outcome, events = owner_run("save_rule", save_body(@rule).merge("id" => @rule.id))

    assert_refused("invalid_state", outcome)
    assert_empty events
    assert_equal 1, @rule.reload.current_version
  end

  test "fields are checked before the rule's state: a removed rule sent fields that do not fit is 422 invalid (IN-13)" do
    @rule.update!(removed_at: scenario.database_now)

    assert_raises(T::Invalid) { owner_command("save_rule", save_body(@rule, on_fail: nil).merge("id" => @rule.id)) }
  end

  test "a rule of another workspace is 404" do
    other = Scenario.new
    other.owner
    foreign = other.rule

    assert_raises(T::NotFound) { owner_command("save_rule", save_body(@rule).merge("id" => foreign.id)) }
  end

  test "trace 17's rule is added, saved with a new wording and saved to only note a failure, as the trace writes it" do
    name = "17-submit-rule-rerun-and-override"
    trace = Leverage::Contract.trace(name).deep_dup
    trace["commands"] = trace.fetch("commands").values_at(0, 15, 29)
    assert_equal %w[add_rule save_rule save_rule], trace.fetch("commands").map { |command| command.fetch("command") }

    runner = TraceRunner.new(name, trace: trace).run

    assert_empty runner.failures
  end
end
