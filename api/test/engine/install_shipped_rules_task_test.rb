require "test_helper"
require_relative "entries/rule_support"

# bin/rails leverage:install_shipped_rules (PRD L434 with Q-12; milestone 4
# plan RD-2, S-1): before the server starts, bin/docker-entrypoint runs it,
# and it applies install_shipped_rules through Timers.apply_workspace, the
# path the sweep uses for a workspace timer, to each workspace that has no
# rules row, and to no other. So an installation upgraded to this milestone
# never runs a command rule-free, and a start on a workspace that has its
# rules writes nothing.
class InstallShippedRulesTaskTest < ActiveSupport::TestCase
  include RuleSupport

  ENTRYPOINT = Rails.root.join("bin/docker-entrypoint")

  setup { Rails.application.load_tasks unless Rake::Task.task_defined?("leverage:install_shipped_rules") }

  def install
    task = Rake::Task["leverage:install_shipped_rules"]
    task.reenable
    out = nil
    calls = recording({ Leverage::Timers => :apply_workspace }) { out, = capture_io { task.invoke } }
    [ out, calls.fetch("Timers.apply_workspace") ]
  end

  def rule_events(scenario) = Event.where(workspace_id: scenario.workspace_id, type: "rule.created").order(:seq).to_a

  test "a workspace with no rule gets the seven, as the app through apply_workspace; one with a rule gets none" do
    bare = Scenario.new
    bare.owner
    bare.task(state: "backlog")
    ruled = Scenario.new
    ruled.owner
    ruled.rule
    before = rule_events(ruled).size

    out, calls = install

    events = rule_events(bare)
    assert_equal 7, events.size
    assert_equal Leverage::Rules::Shipped.all.map(&:key),
      events.map { |event| Rule.find(event.subject_id).key }
    assert_equal [ [ "app", nil, nil ] ], events.map { |event| [ event.actor_kind, event.actor_id, event.command_id ] }.uniq
    assert_equal before, rule_events(ruled).size, "a workspace with a rule writes none"
    installed = calls.map { |call| call.arguments.first.then { |workspace| workspace.respond_to?(:id) ? workspace.id : workspace } }
    assert_includes installed, bare.workspace_id
    refute_includes installed, ruled.workspace_id
    assert(calls.all? { |call| call.arguments[1].to_s == "install_shipped_rules" && call.keywords.key?(:at) })
    assert_match(/install_shipped_rules: workspace #{bare.workspace_id}: wrote the 7 shipped rules/, out)
    refute_match(/#{ruled.workspace_id}/, out)
  end

  test "a second run writes nothing" do
    bare = Scenario.new
    bare.owner
    install
    counts = [ Rule.count, RuleVersion.count, Event.count ]

    _, calls = install

    assert_equal counts, [ Rule.count, RuleVersion.count, Event.count ]
    refute_includes calls.map { |call| call.arguments.first }, bare.workspace_id
  end

  test "bin/docker-entrypoint runs it after db:prepare and before the server starts, as the owner role (RD-2)" do
    text = File.read(ENTRYPOINT)
    server = text[/^if \$server; then\n(.*?)^fi$/m, 1]

    refute_nil server, "the entrypoint has its server branch"
    prepare = server.index("db:prepare")
    install = server.index("leverage:install_shipped_rules")
    refute_nil prepare
    refute_nil install, "the server branch installs the shipped rules"
    assert_operator prepare, :<, install, "after db:prepare, which runs db:grants"
    assert_operator text.index("leverage:install_shipped_rules"), :<, text.index('export DATABASE_URL="${API_DATABASE_URL}"'),
      "before the server switches to the login role"
    assert_equal 1, text.scan("leverage:install_shipped_rules").size, "only for the server"
  end
end
