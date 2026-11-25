require "test_helper"
require_relative "../support/http_calls"

class ImaginariumTasksTest < ActionDispatch::IntegrationTest
  include OpenapiAssertions
  include HttpCalls

  setup do
    @scenario = Scenario.new
    @token = @scenario.owner_token
    Leverage::Timers.apply_workspace(@scenario.workspace, "install_imaginarium_project", at: @scenario.database_now)
    @project_id = @scenario.workspace.reload.imaginarium_project_id
  end

  test "saving to Ideas is idempotent and the promoted task has its gallery criteria" do
    key = new_key
    request = source.merge("state" => "ideas", "criteria" => checks)
    task_id = add(request, key: key)
    assert_equal task_id, add(request, key: key)
    assert_equal 1, Task.where(workspace_id: @scenario.workspace_id).count

    call("promote_task", token: @token, key: new_key, ids: { "id" => task_id })
    assert_response :ok
    assert_response_matches_contract
    call("get_task", token: @token, ids: { "id" => task_id })
    assert_response :ok
    assert_response_matches_contract
    page = response.parsed_body
    assert_equal [ @project_id, "backlog", "pocket-to-do", 1 ],
      page.fetch("task").values_at("project_id", "state", "imaginarium_entry_id", "imaginarium_catalog_version")
    assert_equal checks, page.fetch("criteria").map { |criterion| criterion.slice("text", "kind") }
    assert_empty Leverage::Replay.diff(@scenario.workspace_id)
    assert_empty Leverage::LogAudit.call(@scenario.workspace_id)
  end

  test "sending to Ready uses ordinary Add task followed by Complete contract" do
    task_id = add(source)
    assert_equal "backlog", Task.find(task_id).state
    contract = source.slice("title", "details").merge("criteria" => checks, "actions" => [],
      "minimum_strength_rank" => nil, "budget_cap" => nil, "work_reference" => nil)
    call("complete_contract", token: @token, key: new_key, ids: { "id" => task_id }, body: contract)
    assert_response :ok
    assert_response_matches_contract
    assert_equal [ @project_id, "ready", "pocket-to-do" ], Task.find(task_id).values_at(:project_id, :state, :imaginarium_entry_id)
    assert_empty Leverage::Replay.diff(@scenario.workspace_id)
    assert_empty Leverage::LogAudit.call(@scenario.workspace_id)
  end

  private

  def source
    { "title" => "Pocket to-do", "details" => "Create a checklist that saves locally.",
      "imaginarium" => { "entry_id" => "pocket-to-do", "catalog_version" => 1 } }
  end

  def checks
    [ { "text" => "It opens on the Mac.", "kind" => "build" },
      { "text" => "Tasks are kept.", "kind" => "build" },
      { "text" => "A second agent reviews the work", "kind" => "review" } ]
  end

  def add(body, key: new_key)
    call("add_task", token: @token, key: key, body: body)
    assert_response :ok
    assert_response_matches_contract
    response.parsed_body.fetch("result").fetch("task_id")
  end
end
