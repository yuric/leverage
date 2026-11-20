require "test_helper"
require_relative "rule_support"
require_relative "../../support/trace_runner"

# Entries::InstallShippedRules (PRD L434 with Q-12; milestone 4 plan RD-1
# to RD-3, S-1): the app writes the seven shipped rules of a workspace that
# has none, as the app with no key, through Timers.apply_workspace (the
# path the sweep uses for a workspace timer). A workspace that has any rule
# is refused invalid_state and gets nothing.
class InstallShippedRulesTest < ActiveSupport::TestCase
  include RuleSupport

  setup { use_scenario }

  def install(at: scenario.database_now) = Leverage::Timers.apply_workspace(scenario.workspace, "install_shipped_rules", at: at)

  def events = Event.where(workspace_id: scenario.workspace_id).order(:seq)

  test "it writes rule.created for each shipped rule, as the app with no key, after the workspace's earlier events" do
    task = scenario.task(state: "backlog")
    before = scenario.workspace.reload.last_seq
    at = scenario.database_now

    outcome = install(at: at)

    assert_completed(outcome)
    written = events.where("seq > ?", before).to_a
    rules = Rule.where(workspace_id: scenario.workspace_id).to_a.index_by(&:id)
    assert_equal [ "rule.created" ] * 7, written.map(&:type)
    assert_equal Leverage::Rules::Shipped.all.map(&:key), written.map { |event| rules.fetch(event.subject_id).key }
    written.each do |event|
      assert_equal [ "app", nil, nil, nil ], [ event.actor_kind, event.actor_id, event.command_id, event.task_id ]
      assert_equal at, event.effective_at, "the time apply_workspace was given"
    end
    assert_equal [ [ "app", nil ] ], RuleVersion.where(workspace_id: scenario.workspace_id).distinct.pluck(:author_kind, :author_id)
    assert_equal "backlog", task.reload.state, "a task already made is not touched (L379, RD-3)"
    assert_nil Command.find_by(workspace_id: scenario.workspace_id, command: "install_shipped_rules"), "no key, no commands row"
  end

  test "a workspace that has any rule is refused invalid_state and gets nothing" do
    scenario.rule
    counts = [ Rule.count, Event.count ]

    outcome = install

    assert_refused("invalid_state", outcome)
    assert_equal counts, [ Rule.count, Event.count ]
  end

  test "a second run on the same workspace writes nothing" do
    install
    counts = [ Rule.count, RuleVersion.count, Event.count ]

    assert_refused("invalid_state", install)
    assert_equal counts, [ Rule.count, RuleVersion.count, Event.count ]
  end

  test "trace 19's first command: the seven rule.created on a workspace with none" do
    runner = TraceRunner.new("19-provider-rule-offline-and-jobs").run(1)

    assert_empty runner.failures
    assert_equal 7, Rule.where(workspace_id: runner.workspace_id).count
  end
end
