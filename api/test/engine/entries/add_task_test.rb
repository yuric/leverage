require "test_helper"

# Add task (PRD Lifecycle L77; milestone 2 plan SC-3, SC-4, SC-8): the owner
# adds a task to the Backlog, or to the Imaginarium now that Promote exists
# (milestone 3 plan HE-24), and task.created is written. A project, criteria
# and outward actions are 422 invalid in this milestone.
class AddTaskTest < ActiveSupport::TestCase
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
    { "title" => "Update the pricing page", "goal" => "The page shows this year's prices." }.merge(fields.stringify_keys)
  end

  test "adds a task to the Backlog with task.created" do
    outcome = apply(body(details: "Use the price list.", priority: "high", work_reference: "~/work/pricing-page",
      state: "backlog"))

    assert outcome.completed?
    task = Task.find(outcome.result.fetch("task_id"))
    assert_equal [ "Update the pricing page", "The page shows this year's prices.", "Use the price list.",
                   "~/work/pricing-page", "high", "backlog", 0, 0, nil, nil ],
      task.attributes.values_at("title", "goal", "details", "work_reference", "priority", "state", "round",
        "contract_version", "holder_seat_id", "project_id")
    event = written.sole
    assert_equal [ "task.created", "owner", @owner.id, task.id, 0, nil, { "state" => "backlog" } ],
      [ event.type, event.actor_kind, event.actor_id, event.task_id, event.round, event.subject_kind, event.payload ]
  end

  test "the Backlog and normal priority are the defaults" do
    task = Task.find(apply(body).result.fetch("task_id"))
    assert_equal %w[backlog normal], [ task.state, task.priority ]
  end

  test "a task added to the Imaginarium is an idea, with task.created there (HE-24)" do
    outcome = apply(body(state: "imaginarium"))

    assert outcome.completed?
    task = Task.find(outcome.result.fetch("task_id"))
    assert_equal "imaginarium", task.state
    event = written.sole
    assert_equal [ "task.created", { "state" => "imaginarium" } ], [ event.type, event.payload ]
    assert_equal [ [ "idea", event.id ] ], TaskStep.where(task_id: task.id).pluck(:kind, :opening_event_id)
  end

  test "a state other than the Imaginarium or the Backlog is 422 invalid" do
    assert_raises(T::Invalid) { apply(body(state: "ready")) }
    assert_equal 0, Task.where(workspace_id: @scenario.workspace_id).count
  end

  test "a project, criteria and outward actions are 422 invalid (SC-8, SC-3)" do
    project = @scenario.project
    [ body(project_id: project.id),
      body(criteria: [ { "text" => "Made-up.", "kind" => "build" } ]),
      body(actions: [ { "kind" => "publish", "description" => "Made-up." } ]) ].each do |params|
      assert_raises(T::Invalid) { apply(params) }
    end
    assert_equal 0, Task.where(workspace_id: @scenario.workspace_id).count
  end

  test "empty criteria and actions are accepted" do
    assert apply(body(criteria: [], actions: [], project_id: nil)).completed?
  end

  test "a work reference with sign-in details is 422 invalid (L533)" do
    assert_raises(T::Invalid) { apply(body(work_reference: "https://made-up-user:made-up-pass@example.test/repo")) }
    assert_equal 0, Task.where(workspace_id: @scenario.workspace_id).count
  end
end
