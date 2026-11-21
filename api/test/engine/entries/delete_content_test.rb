require "test_helper"
require_relative "accounts_support"

class DeleteContentTest < ActiveSupport::TestCase
  include AccountsSupport

  setup { use_scenario }

  (Leverage::Contract.list("task_states") - %w[done cancelled]).each do |state|
    test "refuses a #{state} task and a project containing it" do
      project = scenario.project
      task = state == "finishing" ? scenario.finishing_task(project: project) : scenario.task(state: state, project: project)
      finished = scenario.task(state: "cancelled", project: project)
      before = [ task.attributes, finished.attributes, project.attributes ]

      written = events_written do
        assert_refused "invalid_state", owner_command("delete_content", { task_id: task.id })
        assert_refused "invalid_state", owner_command("delete_content", { project_id: project.id })
      end

      assert_empty written
      assert_equal before, [ task.reload.attributes, finished.reload.attributes, project.reload.attributes ]
    end
  end

  test "accepts an empty project and refuses a second deletion of the same task or project" do
    task = scenario.task(state: "cancelled")
    project = scenario.project
    [ { task_id: task.id }, { project_id: project.id } ].each do |target|
      request = owner_request("delete_content", target)
      assert_equal [ "content.deleted" ], events_written { assert_completed T.apply(request) }.map(&:type)
      assert_empty events_written { assert_completed T.apply(request) }
      assert_empty events_written { assert_refused "invalid_state", owner_command("delete_content", target) }
    end
  end

  test "loads the requested kind only inside the caller's workspace" do
    outside = Scenario.new
    task = outside.task(state: "cancelled")
    project = outside.project
    local = scenario.project(id: task.id)
    local_task = scenario.task(state: "cancelled", id: project.id)

    assert_raises(Leverage::Transitions::NotFound) { owner_command("delete_content", { task_id: task.id }) }
    assert_raises(Leverage::Transitions::NotFound) { owner_command("delete_content", { project_id: project.id }) }
    assert_completed owner_command("delete_content", { project_id: local.id })
    assert local.reload.content_deleted_at
    assert_nil project.reload.content_deleted_at
    assert_nil task.reload.content_deleted_at
    assert_nil local_task.reload.content_deleted_at
  end

  test "refuses missing or ambiguous internal targets" do
    task = scenario.task(state: "cancelled")
    project = scenario.project
    assert_raises(Leverage::Transitions::Invalid) { owner_command("delete_content") }
    assert_raises(Leverage::Transitions::Invalid) do
      owner_command("delete_content", { task_id: task.id, project_id: project.id })
    end
  end
end
