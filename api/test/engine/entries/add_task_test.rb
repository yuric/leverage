require "test_helper"
require_relative "call_spy"

# Add task (PRD Lifecycle L77; milestone 2 plan SC-3, SC-4, SC-8): the owner
# adds a task to the Backlog, or to Ideas now that Promote exists
# (milestone 3 plan HE-24), and task.created is written. Complete contract
# writes criteria. The task can name a project in the workspace (RD-52).
class AddTaskTest < ActiveSupport::TestCase
  include CallSpy

  T = Leverage::Transitions

  setup do
    @scenario = Scenario.new
    @owner = @scenario.owner
  end

  def apply(params)
    key = "key-#{SecureRandom.hex(6)}"
    @key = key
    T.apply(T::Request.new(command: "add_task", workspace_id: @scenario.workspace_id, caller_kind: "owner",
      caller_id: @owner.id, key: key, request_hash: Digest::SHA256.hexdigest(params.to_json), params: params))
  end

  def written = Event.where(workspace_id: @scenario.workspace_id, command_id: @key).order(:seq).to_a

  def body(**fields)
    { "title" => "Update the pricing page" }.merge(fields.stringify_keys)
  end

  test "adds a task to the Backlog with task.created" do
    outcome = apply(body(details: "Use the price list.", priority: "high", work_reference: "~/work/pricing-page",
      state: "backlog"))

    assert outcome.completed?
    task = Task.find(outcome.result.fetch("task_id"))
    assert_equal [ "Update the pricing page", "Use the price list.",
                   "~/work/pricing-page", "high", "backlog", 0, 0, nil, nil ],
      task.attributes.values_at("title", "details", "work_reference", "priority", "state", "round",
        "contract_version", "holder_seat_id", "project_id")
    event = written.sole
    assert_equal [ "task.created", "owner", @owner.id, task.id, 0, nil, { "state" => "backlog", "added_action_ids" => [] } ],
      [ event.type, event.actor_kind, event.actor_id, event.task_id, event.round, event.subject_kind, event.payload ]
  end

  test "the Backlog and normal priority are the defaults" do
    task = Task.find(apply(body).result.fetch("task_id"))
    assert_equal %w[backlog normal], [ task.state, task.priority ]
  end

  test "a task added to Ideas is an idea, with task.created there (HE-24)" do
    outcome = apply(body(state: "ideas"))

    assert outcome.completed?
    task = Task.find(outcome.result.fetch("task_id"))
    assert_equal "ideas", task.state
    event = written.sole
    assert_equal [ "task.created", { "state" => "ideas", "added_action_ids" => [] } ], [ event.type, event.payload ]
    assert_equal [ [ "idea", event.id ] ], TaskStep.where(task_id: task.id).pluck(:kind, :opening_event_id)
  end

  test "a state other than Ideas or the Backlog is 422 invalid" do
    assert_raises(T::Invalid) { apply(body(state: "ready")) }
    assert_equal 0, Task.where(workspace_id: @scenario.workspace_id).count
  end

  test "a project of the workspace is the task's, and task.created carries it (RD-52)" do
    project = @scenario.project
    outcome = apply(body(project_id: project.id))

    assert outcome.completed?
    task = Task.find(outcome.result.fetch("task_id"))
    assert_equal project.id, task.project_id
    assert_equal [ [ "task.created", project.id, task.id ] ], written.map { |event| [ event.type, event.project_id, event.task_id ] }
  end

  test "a project id that names no project of the workspace is 422 invalid (RD-52)" do
    elsewhere = Scenario.new.project
    [ SecureRandom.uuid, elsewhere.id, "not-a-uuid" ].each do |project_id|
      assert_raises(T::Invalid, project_id) { apply(body(project_id: project_id)) }
    end
    assert_equal 0, Task.where(workspace_id: @scenario.workspace_id).count
  end

  test "criteria are 422 invalid until Complete contract" do
    assert_raises(T::Invalid) { apply(body(criteria: [ { "text" => "Made-up.", "kind" => "build" } ])) }
    assert_equal 0, Task.where(workspace_id: @scenario.workspace_id).count
  end

  test "an Imaginarium idea keeps its criteria and catalog source without logging their text or version" do
    Leverage::Timers.apply_workspace(@scenario.workspace, "install_imaginarium_project", at: @scenario.database_now)
    source = { "entry_id" => "pocket-to-do", "catalog_version" => 2 }
    criteria = [ { "text" => "Opens on the Mac.", "kind" => "build" },
      { "text" => "Saves changes.", "kind" => "build" },
      { "text" => "A second agent reviews the work", "kind" => "review" } ]
    outcome = apply(body(state: "ideas", details: "Make a little planner.", imaginarium: source, criteria: criteria))
    task = Task.find(outcome.result.fetch("task_id"))
    assert_equal [ @scenario.workspace.reload.imaginarium_project_id, "pocket-to-do", 2, 0 ],
      task.attributes.values_at("project_id", "imaginarium_entry_id", "imaginarium_catalog_version", "contract_version")
    stored = Criterion.where(task_id: task.id).order(:position)
    assert_equal criteria.map { |criterion| criterion.values_at("text", "kind") }, stored.pluck(:text, :kind)
    assert_equal({ "state" => "ideas", "added_action_ids" => [], "imaginarium_entry" => "pocket-to-do",
      "added_criterion_ids" => stored.ids }, written.sole.payload)
    assert_equal 2, written.sole.schema_version
    assert_equal [ "pocket-to-do", 2 ], Leverage::Reads::Shapes.task_summary(task)
      .values_at(:imaginarium_entry_id, :imaginarium_catalog_version)
    assert_empty Leverage::Replay.diff(@scenario.workspace_id)
    assert_empty Leverage::LogAudit.call(@scenario.workspace_id)
  end

  test "Imaginarium tasks use the recorded project and Backlog tasks still complete their contract separately" do
    Leverage::Timers.apply_workspace(@scenario.workspace, "install_imaginarium_project", at: @scenario.database_now)
    source = { "entry_id" => "pocket-to-do", "catalog_version" => 1 }
    other = @scenario.project
    assert_raises(T::Invalid) { apply(body(imaginarium: source, project_id: other.id)) }
    assert_raises(T::Invalid) { apply(body(imaginarium: source, state: "ideas")) }
    assert_raises(T::Invalid) { apply(body(imaginarium: source.merge("entry_id" => "unlisted-prompt"))) }
    task = Task.find(apply(body(imaginarium: source)).result.fetch("task_id"))
    assert_equal @scenario.workspace.reload.imaginarium_project_id, task.project_id
    assert_equal "backlog", task.state
    assert_empty Criterion.where(task_id: task.id)
    assert_equal({ "state" => "backlog", "added_action_ids" => [], "imaginarium_entry" => "pocket-to-do",
      "added_criterion_ids" => [] }, written.sole.payload)
  end

  test "adds contracted outward actions in the order given" do
    outcome = apply(body(actions: [ { "kind" => "send", "description" => "Send the update." },
                                   { "kind" => "publish", "description" => "Publish the prices." } ]))

    assert outcome.completed?
    task = Task.find(outcome.result.fetch("task_id"))
    assert_equal [ [ 1, "send", "Send the update.", "contracted" ], [ 2, "publish", "Publish the prices.", "contracted" ] ],
      Action.where(task_id: task.id).order(:position).pluck(:position, :kind, :description, :state)
  end

  test "applies the project's pause to a newly created task" do
    project = @scenario.project(paused: true)
    outcome = nil
    calls = spy_on(Leverage::Projects, :hold_if_paused) do
      outcome = apply(body(project_id: project.id))
    end

    assert outcome.completed?
    assert_equal [ outcome.result.fetch("task_id") ], calls.map { |call| call.arguments.last.id }
  end

  test "empty criteria and actions are accepted" do
    assert apply(body(criteria: [], actions: [], project_id: nil)).completed?
  end

  test "a work reference with sign-in details is 422 invalid (L533)" do
    assert_raises(T::Invalid) { apply(body(work_reference: "https://made-up-user:made-up-pass@example.test/repo")) }
    assert_equal 0, Task.where(workspace_id: @scenario.workspace_id).count
  end
end
