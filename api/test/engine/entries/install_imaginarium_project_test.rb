require "test_helper"

# Entries::InstallImaginariumProject (DB-53, IM-6): the app creates the
# Imaginarium project of a workspace that has none, as the app with no key,
# through Timers.apply_workspace. A workspace that has one is refused
# invalid_state and gets nothing.
class InstallImaginariumProjectTest < ActiveSupport::TestCase
  setup do
    @scenario = Scenario.new
    @scenario.owner
  end

  def install = Leverage::Timers.apply_workspace(@scenario.workspace, "install_imaginarium_project", at: @scenario.database_now)

  def projects = Project.where(workspace_id: @scenario.workspace_id)

  test "a workspace with none gets the project, recorded by id, with project.created as the app" do
    outcome = install

    assert outcome.completed?
    project = projects.sole
    assert_equal "Imaginarium", project.name
    assert_equal project.id, @scenario.workspace.reload.imaginarium_project_id
    event = Event.where(workspace_id: @scenario.workspace_id, type: "project.created").sole
    assert_equal({ "imaginarium" => true }, event.payload)
    assert_equal [ project.id, "app", nil, nil ], [ event.project_id, event.actor_kind, event.actor_id, event.command_id ]
    assert_nil Command.find_by(workspace_id: @scenario.workspace_id, command: "install_imaginarium_project"), "no key, no commands row"
  end

  test "a second run is refused invalid_state and creates nothing" do
    install
    counts = [ Project.count, Event.count ]

    outcome = install

    assert outcome.refused?
    assert_equal "invalid_state", outcome.refusal.code
    assert_equal counts, [ Project.count, Event.count ]
  end

  test "another project does not stand in for the Imaginarium project" do
    @scenario.project(name: "Imaginarium")

    assert install.completed?
    assert_equal 2, projects.count
  end
end
