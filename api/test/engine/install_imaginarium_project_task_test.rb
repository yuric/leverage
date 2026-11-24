require "test_helper"
require_relative "entries/rule_support"

# bin/rails leverage:install_imaginarium_project (DB-53, IM-6): before the
# server starts, bin/docker-entrypoint runs it, and it applies
# install_imaginarium_project through Timers.apply_workspace to each
# workspace with no Imaginarium project, and to no other.
class InstallImaginariumProjectTaskTest < ActiveSupport::TestCase
  include RuleSupport

  ENTRYPOINT = Rails.root.join("bin/docker-entrypoint")

  setup { Rails.application.load_tasks unless Rake::Task.task_defined?("leverage:install_imaginarium_project") }

  def install
    task = Rake::Task["leverage:install_imaginarium_project"]
    task.reenable
    out = nil
    calls = recording({ Leverage::Timers => :apply_workspace }) { out, = capture_io { task.invoke } }
    [ out, calls.fetch("Timers.apply_workspace") ]
  end

  def created(scenario) = Event.where(workspace_id: scenario.workspace_id, type: "project.created").to_a

  test "a workspace with no Imaginarium project gets one; one that has it gets none" do
    bare = Scenario.new
    bare.owner
    done = Scenario.new
    done.owner
    Leverage::Timers.apply_workspace(done.workspace, "install_imaginarium_project", at: done.database_now)
    before = created(done).size

    out, calls = install

    assert_equal 1, created(bare).size
    assert_equal before, created(done).size, "a workspace that has one writes none"
    assert_equal "Imaginarium", Project.find(bare.workspace.reload.imaginarium_project_id).name
    installed = calls.map { |call| call.arguments.first.then { |workspace| workspace.respond_to?(:id) ? workspace.id : workspace } }
    assert_includes installed, bare.workspace_id
    refute_includes installed, done.workspace_id
    assert(calls.all? { |call| call.arguments[1].to_s == "install_imaginarium_project" && call.keywords.key?(:at) })
    assert_match(/install_imaginarium_project: workspace #{bare.workspace_id}: wrote the project/, out)
    refute_match(/#{done.workspace_id}/, out)
  end

  test "a second run writes nothing" do
    bare = Scenario.new
    bare.owner
    install
    counts = [ Project.count, Event.count ]

    install

    assert_equal counts, [ Project.count, Event.count ]
  end

  test "the entrypoint runs it right after install_shipped_rules, before the server starts" do
    lines = ENTRYPOINT.read.lines.map(&:strip)
    shipped = lines.index("./bin/rails leverage:install_shipped_rules")
    assert shipped
    assert_equal "./bin/rails leverage:install_imaginarium_project", lines[shipped + 1]
  end
end
